import EditorCore
import Localization
import RawProcessingCore
import SwiftUI

/// The spot heal / clone drag overlay, drawn on top of the photo while
/// `EditorSession.toolMode == .spotHeal` (design spec §6.7, roadmap Phase 4
/// Task 4.5). Three independent handles per entry:
///
/// - a **target** handle (drag to move the point being retouched);
/// - a **size** handle at a fixed bearing from the target (drag to change
///   `radius` -- distance from the target, normalized to the shorter side
///   of the frame, matching `SpotHealDragMath.updatedRadius`'s own
///   normalization exactly so the drawn circle always matches the actual
///   render);
/// - a **source** handle, shown only in `.clone` mode (drag to move where
///   content is sampled from).
///
/// `.heal` mode never shows a source handle: the render falls back to
/// `LocalAdjustmentRenderer.autoSourcePoint`'s fixed, deterministic offset,
/// which this overlay deliberately does not expose as something to drag --
/// dragging it would silently imply clone semantics the user never asked
/// for. Every edit goes through `EditorSession.updateAdjustments(_:)`, the
/// same undo/autosave path every other adjustment control in this app
/// already uses (same pattern as `LinearGradientOverlayView`).
struct SpotHealOverlayView: View {
    @ObservedObject var editor: EditorSession
    /// The fitted image rect from `AspectFitRect.fitting(...)` -- the same
    /// rectangle every other overlay draws and hit-tests against.
    let imageFrame: CGRect

    /// The geometry at the moment the current drag began, keyed by which
    /// `LocalAdjustment.id` is being dragged. A source drag's captured base
    /// always has a concrete `sourceX`/`sourceY` (resolved via
    /// `SpotHealDragMath.resolvedSource(for:)` first if the model still has
    /// `nil`), matching where the handle is actually drawn -- there is no
    /// such thing as dragging from "nowhere". Same reasoning as
    /// `LinearGradientOverlayView.dragBaseGeometry`.
    @State private var dragBaseGeometry: [UUID: LocalAdjustmentGeometry] = [:]

    private static let handleSize: CGFloat = 12
    private static let handleHitAreaSize: CGFloat = 28

    private var spotHeals: [LocalAdjustment] {
        editor.adjustments.localAdjustments.filter { $0.kind == .spotHeal }
    }

    var body: some View {
        ZStack {
            ForEach(spotHeals) { heal in
                handles(for: heal)
            }
        }
    }

    private func handles(for heal: LocalAdjustment) -> some View {
        let geometry = heal.geometry
        let target = targetPoint(for: geometry)
        let sizeHandlePoint = self.sizeHandlePoint(for: geometry)
        let viewRadius = sizeHandlePoint.x - target.x
        let isSelected = editor.selectedLocalAdjustmentID == heal.id

        return ZStack {
            Circle()
                .stroke(Color.white.opacity(isSelected ? 0.7 : 0.35), lineWidth: 1)
                .frame(width: max(viewRadius, 1) * 2, height: max(viewRadius, 1) * 2)
                .position(target)
                .allowsHitTesting(false)

            if geometry.healMode == .clone {
                let source = sourcePoint(for: geometry)
                Path { path in
                    path.move(to: target)
                    path.addLine(to: source)
                }
                .stroke(Color.white.opacity(isSelected ? 0.9 : 0.4), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .allowsHitTesting(false)

                handle(
                    at: source,
                    tint: .yellow,
                    filled: isSelected,
                    accessibilityLabel: L10n.t("Spot Heal Source"),
                    drag: sourceDragGesture(for: heal)
                )
            }

            handle(
                at: target,
                tint: .accentColor,
                filled: isSelected,
                accessibilityLabel: L10n.t("Spot Heal Target"),
                drag: targetDragGesture(for: heal)
            )

            if isSelected {
                handle(
                    at: sizeHandlePoint,
                    tint: .accentColor,
                    filled: true,
                    accessibilityLabel: L10n.t("Spot Heal Size"),
                    drag: sizeDragGesture(for: heal)
                )
            }
        }
    }

    private func handle(
        at point: CGPoint,
        tint: Color,
        filled: Bool,
        accessibilityLabel: String,
        drag: some Gesture
    ) -> some View {
        Circle()
            .fill(filled ? tint : Color.white)
            .frame(width: Self.handleSize, height: Self.handleSize)
            .shadow(radius: 1)
            .frame(width: Self.handleHitAreaSize, height: Self.handleHitAreaSize)
            .contentShape(Circle())
            .position(point)
            .gesture(drag)
            .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Geometry <-> view space

    private func targetPoint(for geometry: LocalAdjustmentGeometry) -> CGPoint {
        CGPoint(
            x: imageFrame.minX + geometry.x * imageFrame.width,
            y: imageFrame.minY + geometry.y * imageFrame.height
        )
    }

    private func sourcePoint(for geometry: LocalAdjustmentGeometry) -> CGPoint {
        let resolved = SpotHealDragMath.resolvedSource(for: geometry)
        return CGPoint(
            x: imageFrame.minX + resolved.x * imageFrame.width,
            y: imageFrame.minY + resolved.y * imageFrame.height
        )
    }

    /// Placed directly to the visual right of the target, at a view-space
    /// distance of `radius` normalized to the shorter side of the frame --
    /// the exact inverse of `SpotHealDragMath.updatedRadius`'s own
    /// normalization, so the circle drawn here always matches what
    /// `LocalAdjustmentRenderer.applySpotHeal` will actually render.
    private func sizeHandlePoint(for geometry: LocalAdjustmentGeometry) -> CGPoint {
        let target = targetPoint(for: geometry)
        let shorterSide = min(imageFrame.width, imageFrame.height)
        let distance = max(CGFloat(geometry.radius), 0.01) * shorterSide
        return CGPoint(x: target.x + distance, y: target.y)
    }

    // MARK: - Gestures

    private func targetDragGesture(for heal: LocalAdjustment) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                editor.selectedLocalAdjustmentID = heal.id
                let base = dragBaseGeometry[heal.id] ?? heal.geometry
                if dragBaseGeometry[heal.id] == nil { dragBaseGeometry[heal.id] = base }
                let updated = SpotHealDragMath.updatedTargetPosition(
                    base: base,
                    translation: value.translation,
                    imageFrameSize: imageFrame.size
                )
                setGeometry(updated, for: heal.id)
            }
            .onEnded { _ in dragBaseGeometry[heal.id] = nil }
    }

    private func sourceDragGesture(for heal: LocalAdjustment) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                editor.selectedLocalAdjustmentID = heal.id
                let base = dragBaseGeometry[heal.id] ?? Self.resolvedSourceBase(heal.geometry)
                if dragBaseGeometry[heal.id] == nil { dragBaseGeometry[heal.id] = base }
                let updated = SpotHealDragMath.updatedSourcePosition(
                    base: base,
                    translation: value.translation,
                    imageFrameSize: imageFrame.size
                )
                setGeometry(updated, for: heal.id)
            }
            .onEnded { _ in dragBaseGeometry[heal.id] = nil }
    }

    private func sizeDragGesture(for heal: LocalAdjustment) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                editor.selectedLocalAdjustmentID = heal.id
                let base = dragBaseGeometry[heal.id] ?? heal.geometry
                if dragBaseGeometry[heal.id] == nil { dragBaseGeometry[heal.id] = base }

                let target = targetPoint(for: base)
                let baseHandle = sizeHandlePoint(for: base)
                let newHandle = CGPoint(x: baseHandle.x + value.translation.width, y: baseHandle.y + value.translation.height)
                let updated = SpotHealDragMath.updatedRadius(
                    base: base,
                    targetToHandleTranslation: CGVector(dx: newHandle.x - target.x, dy: newHandle.y - target.y),
                    imageFrameSize: imageFrame.size
                )
                setGeometry(updated, for: heal.id)
            }
            .onEnded { _ in dragBaseGeometry[heal.id] = nil }
    }

    /// Fills in a concrete `sourceX`/`sourceY` before a source drag's first
    /// `onChanged` fires, so dragging from an unset clone source starts
    /// from the same point the handle is drawn at (see `sourcePoint(for:)`)
    /// rather than jumping there on the first pixel of movement.
    private static func resolvedSourceBase(_ geometry: LocalAdjustmentGeometry) -> LocalAdjustmentGeometry {
        var result = geometry
        let resolved = SpotHealDragMath.resolvedSource(for: geometry)
        result.sourceX = resolved.x
        result.sourceY = resolved.y
        return result
    }

    private func setGeometry(_ geometry: LocalAdjustmentGeometry, for id: UUID) {
        editor.updateAdjustments { adjustments in
            guard let index = adjustments.localAdjustments.firstIndex(where: { $0.id == id }) else { return }
            adjustments.localAdjustments[index].geometry = geometry
        }
    }
}
