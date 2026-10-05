import EditorCore
import Localization
import RawProcessingCore
import SwiftUI

/// Shared canvas overlay for the source-coordinate adjustment brush.
///
/// This view deliberately has no legacy `LocalAdjustment` access.  Both Mac
/// and iPad feed the same `EditorSession` gesture API, while the mapper is
/// built from the geometry renderer's authoritative transform so the cursor,
/// saved paths, preview and export stay in the same coordinate space.
public struct BrushMaskOverlayView: View {
    @ObservedObject private var editor: EditorSession
    private let imageFrame: CGRect

    @State private var gestureContext: BrushMaskGestureContext?
    @State private var cursorLocation: CGPoint?

    public init(editor: EditorSession, imageFrame: CGRect) {
        self.editor = editor
        self.imageFrame = imageFrame
    }

    private var masks: [BrushMask] {
        editor.adjustments.brushMasks
    }

    private var selectedMaskID: UUID? {
        editor.selectedBrushMaskID
    }

    /// Reverse the final displayed extent into the source extent expected by
    /// `BrushCoordinateMapping`.  GeometryRenderer applies quarter-turns
    /// before crop, so undo those size changes in reverse order.
    private var mapping: BrushCoordinateMapping? {
        guard imageFrame.width > 0, imageFrame.height > 0 else { return nil }
        var sourceSize = imageFrame.size
        if let crop = editor.adjustments.geometry.crop, !crop.isFull,
           crop.width > 0, crop.height > 0 {
            sourceSize = CGSize(width: sourceSize.width / crop.width,
                                height: sourceSize.height / crop.height)
        }
        if editor.adjustments.geometry.rotationDegrees == 90 ||
            editor.adjustments.geometry.rotationDegrees == 270 {
            sourceSize = CGSize(width: sourceSize.height, height: sourceSize.width)
        }
        return try? BrushCoordinateMapping(
            sourceExtent: CGRect(origin: imageFrame.origin, size: sourceSize),
            geometry: editor.adjustments.geometry
        )
    }

    public var body: some View {
        ZStack {
            ForEach(masks) { mask in
                maskOverlay(mask)
            }

            if editor.toolMode == .brushMask {
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .frame(width: imageFrame.width, height: imageFrame.height)
                    .position(x: imageFrame.midX, y: imageFrame.midY)
                    .gesture(paintGesture)
                    .accessibilityLabel(Text(L10n.t("Adjustment Brush")))
                    .accessibilityIdentifier("adjustment-brush-canvas")
            }

            if let cursorLocation, let mapping {
                Circle()
                    .stroke(Color.accentColor, lineWidth: 1.5)
                    .frame(width: cursorDiameter(mapping: mapping), height: cursorDiameter(mapping: mapping))
                    .position(cursorLocation)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .onDisappear {
            editor.cancelBrushMaskGesture()
            gestureContext = nil
            cursorLocation = nil
        }
    }

    @ViewBuilder
    private func maskOverlay(_ mask: BrushMask) -> some View {
        let selected = mask.id == selectedMaskID
        ForEach(mask.strokes) { stroke in
            strokeView(stroke, selected: selected)
        }
    }

    private func strokeView(_ stroke: BrushMaskStroke, selected: Bool) -> AnyView {
        guard let mapping, !stroke.points.isEmpty else { return AnyView(EmptyView()) }
        let points = stroke.points.compactMap { try? mapping.sourceToDisplay($0) }
        guard let first = points.first else { return AnyView(EmptyView()) }
        let width = max(displayDiameter(stroke: stroke, mapping: mapping), 2)
        let color: Color = stroke.mode == .erase ? .orange : .accentColor
        return AnyView(Path { path in
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
        }
        .stroke(color.opacity(selected ? 0.75 : 0.35), style: StrokeStyle(
            lineWidth: width,
            lineCap: .round,
            lineJoin: .round
        ))
        .allowsHitTesting(false)
        .accessibilityHidden(true))
    }

    private var paintGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let location = canvasPoint(value.location)
                let startLocation = canvasPoint(value.startLocation)
                cursorLocation = location
                guard let mapping else { return }
                if gestureContext == nil {
                    gestureContext = editor.beginBrushMaskGesture(
                        at: startLocation,
                        mapping: mapping,
                        settings: editor.brushMaskGestureSettings
                    )
                }
                guard let context = gestureContext else { return }
                _ = editor.appendBrushMaskPoint(at: location, context: context)
            }
            .onEnded { value in
                defer {
                    gestureContext = nil
                    cursorLocation = nil
                }
                guard let context = gestureContext else { return }
                if !editor.endBrushMaskGesture(at: canvasPoint(value.location), context: context) {
                    editor.cancelBrushMaskGesture()
                }
            }
    }

    private func canvasPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: imageFrame.minX + point.x, y: imageFrame.minY + point.y)
    }

    private func displayDiameter(stroke: BrushMaskStroke, mapping: BrushCoordinateMapping) -> CGFloat {
        // `size` is defined against the source image's short side.  The
        // display scale below is derived from the same authoritative extent,
        // rather than from the SwiftUI frame independently.
        let sourceShortSide = min(mapping.sourceExtent.width, mapping.sourceExtent.height)
        let sourceRadius = stroke.size * sourceShortSide / 2
        let displayScale = min(
            mapping.displayExtent.width / max(mapping.sourceExtent.width, 1),
            mapping.displayExtent.height / max(mapping.sourceExtent.height, 1)
        )
        return CGFloat(max(sourceRadius * displayScale * 2 * (1 + stroke.feather), 1))
    }

    private func cursorDiameter(mapping: BrushCoordinateMapping) -> CGFloat {
        let settings = editor.brushMaskGestureSettings
        let sourceShortSide = min(mapping.sourceExtent.width, mapping.sourceExtent.height)
        let sourceRadius = settings.size * sourceShortSide / 2
        let displayScale = min(
            mapping.displayExtent.width / max(mapping.sourceExtent.width, 1),
            mapping.displayExtent.height / max(mapping.sourceExtent.height, 1)
        )
        return CGFloat(max(sourceRadius * displayScale * 2 * (1 + settings.feather), 2))
    }
}
