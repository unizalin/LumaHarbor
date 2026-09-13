import EditorCore
import Localization
import RawProcessingCore
import SwiftUI

/// Pure drag math for the radial mask overlay. Keeping normalized geometry
/// updates here makes the same interaction deterministic on Mac and iPad.
public enum RadialMaskDragMath {
    public enum Axis: Sendable {
        case horizontal
        case vertical
    }

    public static func updatedPosition(
        base: LocalAdjustmentGeometry,
        translation: CGSize,
        imageFrameSize: CGSize
    ) -> LocalAdjustmentGeometry {
        guard imageFrameSize.width > 0, imageFrameSize.height > 0 else { return base }
        var result = base
        result.x = clamp(base.x + Double(translation.width / imageFrameSize.width))
        result.y = clamp(base.y + Double(translation.height / imageFrameSize.height))
        return result
    }

    public static func updatedRadius(
        base: LocalAdjustmentGeometry,
        translation: CGSize,
        axis: Axis,
        imageFrameSize: CGSize
    ) -> LocalAdjustmentGeometry {
        let shorterSide = min(imageFrameSize.width, imageFrameSize.height)
        guard shorterSide > 0 else { return base }
        var result = base
        switch axis {
        case .horizontal:
            result.radius = clamp(base.radius + Double(translation.width / shorterSide), minimum: 0.01)
        case .vertical:
            let baseRadiusY = base.radialRadiusY ?? base.radius
            result.radialRadiusY = clamp(baseRadiusY + Double(translation.height / shorterSide), minimum: 0.01)
        }
        return result
    }

    private static func clamp(_ value: Double, minimum: Double = 0, maximum: Double = 1) -> Double {
        guard value.isFinite else { return minimum }
        return Swift.min(Swift.max(value, minimum), maximum)
    }
}

/// Converts a brush drag location into the normalized top-left-origin space
/// used by `BrushPoint`. Out-of-bounds touches are clamped to the photo edge,
/// so split view, rotation and pointer overshoot cannot create invalid masks.
public enum BrushMaskDragMath {
    public static func normalizedPoint(at location: CGPoint, in imageFrame: CGRect) -> BrushPoint {
        guard imageFrame.width > 0, imageFrame.height > 0 else {
            return BrushPoint(x: 0.5, y: 0.5)
        }
        let x = Swift.min(Swift.max((location.x - imageFrame.minX) / imageFrame.width, 0), 1)
        let y = Swift.min(Swift.max((location.y - imageFrame.minY) / imageFrame.height, 0), 1)
        return BrushPoint(x: Double(x), y: Double(y))
    }
}

/// On-canvas radial mask controls shared by both platform editors. The center
/// handle moves the mask, while the two axis handles independently edit its
/// horizontal and vertical radii; all writes use the editor's normal history,
/// autosave and preview path.
public struct RadialMaskOverlayView: View {
    @ObservedObject private var editor: EditorSession
    private let imageFrame: CGRect

    @State private var dragBaseGeometry: [UUID: LocalAdjustmentGeometry] = [:]

    private static let handleSize: CGFloat = 12
    private static let handleHitAreaSize: CGFloat = 28

    public init(editor: EditorSession, imageFrame: CGRect) {
        self.editor = editor
        self.imageFrame = imageFrame
    }

    private var masks: [LocalAdjustment] {
        editor.adjustments.localAdjustments.filter { $0.kind == .radialGradient }
    }

    public var body: some View {
        ZStack {
            ForEach(masks) { mask in
                controls(for: mask)
            }
        }
    }

    private func controls(for mask: LocalAdjustment) -> some View {
        let center = point(for: mask.geometry)
        let radiusY = mask.geometry.radialRadiusY ?? mask.geometry.radius
        let shorterSide = min(imageFrame.width, imageFrame.height)
        let radiusXPoints = CGFloat(mask.geometry.radius) * shorterSide
        let radiusYPoints = CGFloat(radiusY) * shorterSide
        let horizontal = CGPoint(x: center.x + radiusXPoints, y: center.y)
        let vertical = CGPoint(x: center.x, y: center.y + radiusYPoints)
        let selected = editor.selectedLocalAdjustmentID == mask.id

        return ZStack {
            Ellipse()
                .stroke(Color.white.opacity(selected ? 0.9 : 0.4), lineWidth: 1.5)
                .frame(
                    width: max(radiusXPoints * 2, 2),
                    height: max(radiusYPoints * 2, 2)
                )
                .position(center)
                .allowsHitTesting(false)

            handle(
                at: center,
                filled: selected,
                accessibilityLabel: L10n.t("Mask Position"),
                drag: positionDrag(for: mask)
            )

            if selected {
                handle(
                    at: horizontal,
                    filled: true,
                    accessibilityLabel: L10n.t("Radius"),
                    drag: radiusDrag(for: mask, axis: .horizontal)
                )
                handle(
                    at: vertical,
                    filled: true,
                    accessibilityLabel: L10n.t("Vertical Radius"),
                    drag: radiusDrag(for: mask, axis: .vertical)
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

    private func point(for geometry: LocalAdjustmentGeometry) -> CGPoint {
        CGPoint(
            x: imageFrame.minX + CGFloat(geometry.x) * imageFrame.width,
            y: imageFrame.minY + CGFloat(geometry.y) * imageFrame.height
        )
    }

    private func positionDrag(for mask: LocalAdjustment) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                editor.selectedLocalAdjustmentID = mask.id
                let base = dragBaseGeometry[mask.id] ?? mask.geometry
                if dragBaseGeometry[mask.id] == nil { dragBaseGeometry[mask.id] = base }
                setGeometry(
                    RadialMaskDragMath.updatedPosition(
                        base: base,
                        translation: value.translation,
                        imageFrameSize: imageFrame.size
                    ),
                    for: mask.id
                )
            }
            .onEnded { _ in dragBaseGeometry[mask.id] = nil }
    }

    private func radiusDrag(for mask: LocalAdjustment, axis: RadialMaskDragMath.Axis) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                editor.selectedLocalAdjustmentID = mask.id
                let base = dragBaseGeometry[mask.id] ?? mask.geometry
                if dragBaseGeometry[mask.id] == nil { dragBaseGeometry[mask.id] = base }
                setGeometry(
                    RadialMaskDragMath.updatedRadius(
                        base: base,
                        translation: value.translation,
                        axis: axis,
                        imageFrameSize: imageFrame.size
                    ),
                    for: mask.id
                )
            }
            .onEnded { _ in dragBaseGeometry[mask.id] = nil }
    }

    private func setGeometry(_ geometry: LocalAdjustmentGeometry, for id: UUID) {
        editor.updateAdjustments { adjustments in
            guard let index = adjustments.localAdjustments.firstIndex(where: { $0.id == id }) else { return }
            adjustments.localAdjustments[index].geometry = geometry
        }
    }
}

/// On-canvas brush painting shared by Mac and iPad. Existing strokes remain
/// visible, and a drag appends normalized points to the selected brush mask.
/// The panel still owns size and feather so a stroke can be refined without
/// making the canvas gesture ambiguous.
public struct BrushMaskOverlayView: View {
    @ObservedObject private var editor: EditorSession
    private let imageFrame: CGRect

    @State private var activeStrokeID: UUID?

    public init(editor: EditorSession, imageFrame: CGRect) {
        self.editor = editor
        self.imageFrame = imageFrame
    }

    private var masks: [LocalAdjustment] {
        editor.adjustments.localAdjustments.filter { $0.kind == .brush }
    }

    private var selectedMask: LocalAdjustment? {
        if let id = editor.selectedLocalAdjustmentID {
            return masks.first(where: { $0.id == id })
        }
        return masks.first
    }

    public var body: some View {
        ZStack {
            ForEach(masks) { mask in
                strokeViews(for: mask)
            }

            if editor.toolMode == .brush, selectedMask != nil {
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .frame(width: imageFrame.width, height: imageFrame.height)
                    .position(x: imageFrame.midX, y: imageFrame.midY)
                    .gesture(paintGesture)
                    .accessibilityLabel(Text(L10n.t("Brush")))
            }
        }
    }

    @ViewBuilder
    private func strokeViews(for mask: LocalAdjustment) -> some View {
        let selected = editor.selectedLocalAdjustmentID == mask.id
        ForEach(mask.geometry.brushStrokes) { stroke in
            strokeView(stroke, selected: selected)
        }
    }

    @ViewBuilder
    private func strokeView(_ stroke: BrushStroke, selected: Bool) -> some View {
        let color = selected ? Color.accentColor : Color.white
        let width = max(CGFloat(stroke.radius) * min(imageFrame.width, imageFrame.height) * 2, 2)

        if stroke.points.count == 1, let point = stroke.points.first {
            Circle()
                .fill(color.opacity(selected ? 0.2 : 0.12))
                .overlay(Circle().stroke(color.opacity(selected ? 0.85 : 0.45), lineWidth: 1))
                .frame(width: width, height: width)
                .position(viewPoint(for: point))
                .allowsHitTesting(false)
        } else if stroke.points.count > 1 {
            Path { path in
                guard let first = stroke.points.first else { return }
                path.move(to: viewPoint(for: first))
                for point in stroke.points.dropFirst() {
                    path.addLine(to: viewPoint(for: point))
                }
            }
            .stroke(color.opacity(selected ? 0.8 : 0.4), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            .allowsHitTesting(false)
        }
    }

    private func viewPoint(for point: BrushPoint) -> CGPoint {
        CGPoint(
            x: imageFrame.minX + CGFloat(point.x) * imageFrame.width,
            y: imageFrame.minY + CGFloat(point.y) * imageFrame.height
        )
    }

    private var paintGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                append(point: BrushMaskDragMath.normalizedPoint(at: value.location, in: imageFrame))
            }
            .onEnded { _ in activeStrokeID = nil }
    }

    private func append(point: BrushPoint) {
        guard let mask = selectedMask else { return }
        editor.selectedLocalAdjustmentID = mask.id

        if let activeStrokeID {
            editor.updateAdjustments { adjustments in
                guard let maskIndex = adjustments.localAdjustments.firstIndex(where: { $0.id == mask.id }),
                      let strokeIndex = adjustments.localAdjustments[maskIndex].geometry.brushStrokes.firstIndex(where: { $0.id == activeStrokeID }) else { return }
                let points = adjustments.localAdjustments[maskIndex].geometry.brushStrokes[strokeIndex].points
                if let last = points.last, abs(last.x - point.x) + abs(last.y - point.y) < 0.001 { return }
                adjustments.localAdjustments[maskIndex].geometry.brushStrokes[strokeIndex].points.append(point)
            }
        } else {
            let stroke = BrushStroke(
                points: [point],
                radius: mask.geometry.radius,
                feather: mask.geometry.feather
            )
            activeStrokeID = stroke.id
            editor.updateAdjustments { adjustments in
                guard let index = adjustments.localAdjustments.firstIndex(where: { $0.id == mask.id }) else { return }
                adjustments.localAdjustments[index].geometry.brushStrokes.append(stroke)
            }
        }
    }
}
