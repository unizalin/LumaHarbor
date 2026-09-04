import EditorCore
import Localization
import RawProcessingCore
import SwiftUI

/// The linear gradient drag overlay, drawn on top of the photo while
/// `EditorSession.toolMode == .linearGradient` (design spec §6.6, roadmap
/// Phase 4 Task 4.3). Draws two independent handles per gradient: a center
/// dot (drag to move the gradient's anchor position) and an arrowhead dot at
/// the end of a line pointing in the gradient's direction (drag to set
/// angle + range together, by dragging where the arrow's tip lands). Every
/// edit goes through `EditorSession.updateAdjustments(_:)`, the same
/// undo/autosave path every other adjustment control in this app already
/// uses (same pattern as `CropOverlayView`).
///
/// Coordinate convention: SwiftUI's own space is top-left-origin, y-down --
/// the same space `LocalAdjustmentGeometry.x`/`.y` and `angleDegrees` are
/// documented against (`LocalAdjustmentRenderer`'s own header comment: "0
/// grows stronger toward the visual right, 90 toward the visual bottom").
/// Because SwiftUI is already y-down, a clockwise `angleDegrees` maps
/// directly to `(cos, sin)` here with *no* sign flip -- unlike
/// `LocalAdjustmentRenderer`, which negates the y component specifically
/// because Core Image's own space is y-*up*. Getting this wrong would mean
/// dragging the direction handle down-right produces a gradient that
/// renders as if dragged up-left; pinned by
/// `LinearGradientOverlayContractTests` and the manual screenshot checklist
/// (`docs/testing/beta/PHASE4_MANUAL_CHECKLIST.md`).
struct LinearGradientOverlayView: View {
    @ObservedObject var editor: EditorSession
    /// The fitted image rect from `AspectFitRect.fitting(...)` -- the same
    /// rectangle `CropOverlayView`/`EyedropperOverlayView` draw and hit-test
    /// against, so a handle lines up with the photo pixel for pixel
    /// regardless of window size or aspect ratio.
    let imageFrame: CGRect

    /// The gradient/direction pair's position at the moment the current
    /// drag began, keyed by which `LocalAdjustment.id` is being dragged.
    /// `nil` between drags. Captured once per gesture so cumulative
    /// `translation` (always relative to the gesture's own start point) is
    /// applied against a stable base, matching `CropOverlayView
    /// .dragBaseCrop`'s own reasoning.
    @State private var dragBaseGeometry: [UUID: LocalAdjustmentGeometry] = [:]

    private static let handleSize: CGFloat = 12
    private static let handleHitAreaSize: CGFloat = 28

    private var gradients: [LocalAdjustment] {
        editor.adjustments.localAdjustments.filter { $0.kind == .linearGradient }
    }

    var body: some View {
        ZStack {
            ForEach(gradients) { gradient in
                gradientHandles(for: gradient)
            }
        }
    }

    private func gradientHandles(for gradient: LocalAdjustment) -> some View {
        let anchor = anchorPoint(for: gradient.geometry)
        let directionHandle = directionPoint(for: gradient.geometry)
        let isSelected = editor.selectedLocalAdjustmentID == gradient.id

        return ZStack {
            Path { path in
                path.move(to: anchor)
                path.addLine(to: directionHandle)
            }
            .stroke(Color.white.opacity(isSelected ? 0.9 : 0.4), lineWidth: 1.5)
            .allowsHitTesting(false)

            handle(
                at: anchor,
                filled: isSelected,
                accessibilityLabel: L10n.t("Gradient Position"),
                drag: positionDragGesture(for: gradient)
            )

            if isSelected {
                handle(
                    at: directionHandle,
                    filled: true,
                    accessibilityLabel: L10n.t("Gradient Direction and Range"),
                    drag: directionDragGesture(for: gradient)
                )
            }
        }
    }

    private func handle(
        at point: CGPoint,
        filled: Bool,
        accessibilityLabel: String,
        drag: some Gesture
    ) -> some View {
        Circle()
            .fill(filled ? Color.accentColor : Color.white)
            .frame(width: Self.handleSize, height: Self.handleSize)
            .shadow(radius: 1)
            .frame(width: Self.handleHitAreaSize, height: Self.handleHitAreaSize)
            .contentShape(Circle())
            .position(point)
            .gesture(drag)
            .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Geometry <-> view space

    private func anchorPoint(for geometry: LocalAdjustmentGeometry) -> CGPoint {
        CGPoint(
            x: imageFrame.minX + geometry.x * imageFrame.width,
            y: imageFrame.minY + geometry.y * imageFrame.height
        )
    }

    /// The direction handle sits at the anchor plus `range` (normalized to
    /// the frame's diagonal, matching `LocalAdjustmentRenderer`'s own
    /// `halfLength` calculation exactly, so the handle's on-screen position
    /// always reflects the actual render, not an approximation of it) along
    /// `angleDegrees`.
    private func directionPoint(for geometry: LocalAdjustmentGeometry) -> CGPoint {
        let anchor = anchorPoint(for: geometry)
        let diagonal = (imageFrame.width * imageFrame.width + imageFrame.height * imageFrame.height).squareRoot()
        let halfLength = max(geometry.range, 0.01) * diagonal / 2
        let radians = geometry.angleDegrees * .pi / 180
        return CGPoint(x: anchor.x + cos(radians) * halfLength, y: anchor.y + sin(radians) * halfLength)
    }

    // MARK: - Gestures

    private func positionDragGesture(for gradient: LocalAdjustment) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                editor.selectedLocalAdjustmentID = gradient.id
                let base = dragBaseGeometry[gradient.id] ?? gradient.geometry
                if dragBaseGeometry[gradient.id] == nil { dragBaseGeometry[gradient.id] = base }
                let updated = LinearGradientDragMath.updatedPosition(
                    base: base,
                    translation: value.translation,
                    imageFrameSize: imageFrame.size
                )
                setGeometry(updated, for: gradient.id)
            }
            .onEnded { _ in dragBaseGeometry[gradient.id] = nil }
    }

    private func directionDragGesture(for gradient: LocalAdjustment) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                editor.selectedLocalAdjustmentID = gradient.id
                let base = dragBaseGeometry[gradient.id] ?? gradient.geometry
                if dragBaseGeometry[gradient.id] == nil { dragBaseGeometry[gradient.id] = base }

                let anchor = anchorPoint(for: base)
                let baseHandle = directionPoint(for: base)
                let newHandle = CGPoint(x: baseHandle.x + value.translation.width, y: baseHandle.y + value.translation.height)
                let updated = LinearGradientDragMath.updatedDirection(
                    base: base,
                    anchorToTipTranslation: CGVector(dx: newHandle.x - anchor.x, dy: newHandle.y - anchor.y),
                    imageFrameSize: imageFrame.size
                )
                setGeometry(updated, for: gradient.id)
            }
            .onEnded { _ in dragBaseGeometry[gradient.id] = nil }
    }

    private func setGeometry(_ geometry: LocalAdjustmentGeometry, for id: UUID) {
        editor.updateAdjustments { adjustments in
            guard let index = adjustments.localAdjustments.firstIndex(where: { $0.id == id }) else { return }
            adjustments.localAdjustments[index].geometry = geometry
        }
    }
}
