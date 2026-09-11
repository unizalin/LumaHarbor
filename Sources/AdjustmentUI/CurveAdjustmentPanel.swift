import EditorCore
import Localization
import RawProcessingCore
import SwiftUI

extension ToneCurveChannel: Identifiable {
    public var id: Self { self }

    var localizationKey: String {
        switch self {
        case .composite: return "RGB"
        case .red: return "Red"
        case .green: return "Green"
        case .blue: return "Blue"
        }
    }
}

/// Pure geometry and clamping helpers for the draggable tone curve.
public enum ToneCurveEditorModel {
    /// `channel` defaults to `.composite` for callers that predate
    /// per-channel curves (P3).
    public static func points(for curve: AdvancedToneCurve, channel: ToneCurveChannel = .composite) -> [ToneCurvePoint] {
        let channelPoints = curve.points(for: channel)
        guard !channelPoints.isEmpty, channelPoints.count >= 2 else {
            return ToneCurveMapping.identity
        }
        return channelPoints
    }

    public static func movingPoint(
        _ points: [ToneCurvePoint],
        at index: Int,
        to location: CGPoint,
        in size: CGSize
    ) -> [ToneCurvePoint] {
        guard points.indices.contains(index), size.width > 0, size.height > 0 else { return points }

        let rawX = clamp(Double(location.x / size.width))
        let rawY = clamp(Double(1 - location.y / size.height))
        let previousX = index > points.startIndex ? points[index - 1].x + 0.01 : 0
        let nextX = index < points.index(before: points.endIndex) ? points[index + 1].x - 0.01 : 1
        let x = min(max(rawX, previousX), max(previousX, nextX))

        var result = points
        result[index] = ToneCurvePoint(x: x, y: rawY)
        return result
    }

    public static func nearestPointIndex(
        in points: [ToneCurvePoint],
        to location: CGPoint,
        in size: CGSize,
        maximumDistance: CGFloat = .infinity
    ) -> Int? {
        guard !points.isEmpty, size.width > 0, size.height > 0, maximumDistance >= 0 else { return nil }
        guard let index = points.indices.min(by: { lhs, rhs in
            distanceSquared(screenPoint(for: points[lhs], in: size), location)
                < distanceSquared(screenPoint(for: points[rhs], in: size), location)
        }) else { return nil }
        return distanceSquared(screenPoint(for: points[index], in: size), location)
            <= maximumDistance * maximumDistance ? index : nil
    }

    /// Inserts a new point between the existing endpoints while preserving
    /// strictly increasing x coordinates. Taps near an existing point or an
    /// endpoint are treated as selection attempts rather than duplicates.
    public static func insertingPoint(
        _ points: [ToneCurvePoint],
        at location: CGPoint,
        in size: CGSize
    ) -> [ToneCurvePoint] {
        guard points.count >= 2, size.width > 0, size.height > 0 else { return points }

        let x = clamp(Double(location.x / size.width))
        let y = clamp(Double(1 - location.y / size.height))
        let minimumSpacing = 0.01
        guard x > (points.first?.x ?? 0) + minimumSpacing,
              x < (points.last?.x ?? 1) - minimumSpacing,
              points.allSatisfy({ abs($0.x - x) > minimumSpacing }) else {
            return points
        }

        return (points + [ToneCurvePoint(x: x, y: y)]).sorted { lhs, rhs in
            lhs.x < rhs.x
        }
    }

    /// Removes the control point at `index`, unless it is an endpoint or
    /// removing it would leave fewer than two points. Endpoints anchor the
    /// curve's domain and at least two points are required to draw a line
    /// (spec §5.1: "端點不可刪除，刪除至少保留兩點").
    public static func deletingPoint(_ points: [ToneCurvePoint], at index: Int) -> [ToneCurvePoint] {
        guard canDeletePoint(points, at: index) else { return points }
        var result = points
        result.remove(at: index)
        return result
    }

    public static func canDeletePoint(_ points: [ToneCurvePoint], at index: Int) -> Bool {
        points.count > 2
            && points.indices.contains(index)
            && index != points.startIndex
            && index != points.index(before: points.endIndex)
    }

    /// Inserts a new point at the midpoint of the widest gap between two
    /// adjacent points. Used by VoiceOver's "Add Control Point" action,
    /// which has no on-screen tap location to insert at the way a sighted
    /// drag gesture does.
    public static func insertingAtLargestGap(_ points: [ToneCurvePoint]) -> [ToneCurvePoint] {
        guard points.count >= 2 else { return points }
        guard let widestIndex = zip(points, points.dropFirst()).enumerated()
            .max(by: { $0.element.1.x - $0.element.0.x < $1.element.1.x - $1.element.0.x })?
            .offset
        else { return points }

        let left = points[widestIndex]
        let right = points[widestIndex + 1]
        let midpoint = ToneCurvePoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2)
        var result = points
        result.insert(midpoint, at: widestIndex + 1)
        return result
    }

    public static func screenPoint(for point: ToneCurvePoint, in size: CGSize) -> CGPoint {
        CGPoint(x: CGFloat(point.x) * size.width, y: (1 - CGFloat(point.y)) * size.height)
    }

    private static func distanceSquared(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

public struct CurveAdjustmentPanel: View {
    @ObservedObject private var editor: EditorSession
    @State private var selectedChannel: ToneCurveChannel = .composite

    public init(editor: EditorSession) {
        self.editor = editor
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(L10n.t("Tone curve"), systemImage: "chart.xyaxis.line")
                    .font(.headline)
                Spacer()
                Button(L10n.t("Reset Channel")) {
                    editor.updateAdjustments { $0.advancedToneCurve = $0.advancedToneCurve.resetting(selectedChannel) }
                }
                .controlSize(.small)
                .disabled(editor.adjustments.advancedToneCurve.isIdentity(for: selectedChannel))
                Button(L10n.t("Reset All")) {
                    editor.updateAdjustments { $0.advancedToneCurve = .neutral }
                }
                .controlSize(.small)
                .disabled(editor.adjustments.advancedToneCurve.isIdentity)
            }

            Picker(L10n.t("Tone curve"), selection: $selectedChannel) {
                ForEach(ToneCurveChannel.allCases) { channel in
                    Text(L10n.t(channel.localizationKey)).tag(channel)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel(Text(L10n.t("Tone curve")))

            ToneCurveGraph(
                points: ToneCurveEditorModel.points(for: editor.displayedAdjustments.advancedToneCurve, channel: selectedChannel),
                channel: selectedChannel,
                onChange: { points in
                    editor.previewCurveEdit {
                        $0.advancedToneCurve = $0.advancedToneCurve.settingPoints(points, for: selectedChannel)
                    }
                },
                onGesture: { isEditing in
                    if isEditing {
                        editor.beginAdjustmentGesture()
                    } else {
                        editor.commitCurveEdit()
                        editor.endAdjustmentGesture()
                    }
                }
            )
            .frame(minHeight: 170, maxHeight: 230)

            HStack {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(L10n.t("Drag control point"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var statusText: String {
        let curve = editor.adjustments.advancedToneCurve
        if curve.isIdentity(for: selectedChannel) {
            return L10n.t("No curve applied")
        }
        return String(format: L10n.t("%d control points"), curve.points(for: selectedChannel).count)
    }
}

private struct ToneCurveGraph: View {
    let points: [ToneCurvePoint]
    let channel: ToneCurveChannel
    let onChange: ([ToneCurvePoint]) -> Void
    let onGesture: (Bool) -> Void

    @State private var draggingIndex: Int?
    @State private var selectedIndex: Int?
    @State private var isEditing = false
    @State private var gestureStartLocation: CGPoint?

    /// How far a nudge (drag or a VoiceOver adjustable action tick) moves a
    /// point per step, in normalised 0...1 units.
    private static let nudgeStep = 0.02

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Canvas { context, size in
                    drawGrid(in: &context, size: size)
                }

                ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                    pointHandle(index: index, point: point, size: proxy.size)
                }
            }
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        gestureStartLocation = gestureStartLocation ?? value.startLocation
                        if draggingIndex == nil {
                            draggingIndex = ToneCurveEditorModel.nearestPointIndex(
                                in: points,
                                to: value.startLocation,
                                in: proxy.size,
                                maximumDistance: 28
                            )
                        }
                        guard let index = draggingIndex else { return }
                        selectedIndex = index
                        if !isEditing {
                            isEditing = true
                            onGesture(true)
                        }
                        onChange(ToneCurveEditorModel.movingPoint(
                            points,
                            at: index,
                            to: value.location,
                            in: proxy.size
                        ))
                    }
                    .onEnded { value in
                        if draggingIndex == nil, !isEditing {
                            let location = gestureStartLocation ?? value.location
                            let inserted = ToneCurveEditorModel.insertingPoint(
                                points,
                                at: location,
                                in: proxy.size
                            )
                            if inserted.count > points.count {
                                onGesture(true)
                                onChange(inserted)
                                onGesture(false)
                                selectedIndex = ToneCurveEditorModel.nearestPointIndex(
                                    in: inserted,
                                    to: location,
                                    in: proxy.size
                                )
                            }
                        }
                        draggingIndex = nil
                        gestureStartLocation = nil
                        if isEditing {
                            isEditing = false
                            onGesture(false)
                        }
                    }
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(L10n.t("Tone curve")))
            .accessibilityValue(Text(L10n.t(channel.localizationKey)))
            .accessibilityAction(named: Text(L10n.t("Add Control Point"))) {
                let inserted = ToneCurveEditorModel.insertingAtLargestGap(points)
                guard inserted.count > points.count else { return }
                commit(inserted)
            }
        }
    }

    /// A 44×44 pt hit region and VoiceOver element for one control point --
    /// the visible dot can be much smaller (spec §5.1: "命中區至少 44×44
    /// pt，視覺圓點可小於命中區"). Dragging/inserting stays on the shared
    /// `DragGesture` above; this view only adds tap-to-select, a delete
    /// affordance (long-press/right-click via `contextMenu`), and
    /// accessibility label/value/actions per point.
    private func pointHandle(index: Int, point: ToneCurvePoint, size: CGSize) -> some View {
        let isSelected = selectedIndex == index
        let canDelete = ToneCurveEditorModel.canDeletePoint(points, at: index)
        let dotDiameter: CGFloat = isSelected ? 16 : 12

        return Color.clear
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .overlay(
                Circle()
                    .fill(channelColor)
                    .frame(width: dotDiameter, height: dotDiameter)
                    .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: isSelected ? 2.5 : 1.5))
            )
            .position(ToneCurveEditorModel.screenPoint(for: point, in: size))
            .contextMenu {
                if canDelete {
                    Button(role: .destructive) {
                        delete(at: index)
                    } label: {
                        Label(L10n.t("Delete Control Point"), systemImage: "trash")
                    }
                }
            }
            .accessibilityElement()
            .accessibilityLabel(Text(String(format: L10n.t("Control point %d of %d"), index + 1, points.count)))
            .accessibilityValue(Text("\(Int((point.x * 100).rounded()))%, \(Int((point.y * 100).rounded()))%"))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityAdjustableAction { direction in
                let step = direction == .increment ? Self.nudgeStep : -Self.nudgeStep
                let currentScreenPoint = ToneCurveEditorModel.screenPoint(for: point, in: size)
                let nudged = ToneCurveEditorModel.movingPoint(
                    points,
                    at: index,
                    to: CGPoint(x: currentScreenPoint.x, y: currentScreenPoint.y - step * size.height),
                    in: size
                )
                selectedIndex = index
                commit(nudged)
            }
            .accessibilityActions {
                if canDelete {
                    Button(L10n.t("Delete Control Point")) {
                        delete(at: index)
                    }
                }
            }
    }

    private func delete(at index: Int) {
        let updated = ToneCurveEditorModel.deletingPoint(points, at: index)
        guard updated.count < points.count else { return }
        if selectedIndex == index { selectedIndex = nil }
        commit(updated)
    }

    /// Applies a single, discrete curve change (delete, VoiceOver nudge, or
    /// VoiceOver "Add Control Point") as its own one-entry Undo step,
    /// bracketed the same way a completed drag is.
    private func commit(_ updated: [ToneCurvePoint]) {
        onGesture(true)
        onChange(updated)
        onGesture(false)
    }

    private var channelColor: Color {
        switch channel {
        case .composite: return .accentColor
        case .red: return .red
        case .green: return .green
        case .blue: return .blue
        }
    }

    private func drawGrid(in context: inout GraphicsContext, size: CGSize) {
        let gridColor = Color.secondary.opacity(0.25)
        for step in 0...4 {
            let value = CGFloat(step) / 4
            var horizontal = Path()
            horizontal.move(to: CGPoint(x: 0, y: value * size.height))
            horizontal.addLine(to: CGPoint(x: size.width, y: value * size.height))
            context.stroke(horizontal, with: .color(gridColor), lineWidth: 0.5)

            var vertical = Path()
            vertical.move(to: CGPoint(x: value * size.width, y: 0))
            vertical.addLine(to: CGPoint(x: value * size.width, y: size.height))
            context.stroke(vertical, with: .color(gridColor), lineWidth: 0.5)
        }

        var baseline = Path()
        baseline.move(to: CGPoint(x: 0, y: size.height))
        baseline.addLine(to: CGPoint(x: size.width, y: 0))
        context.stroke(
            baseline,
            with: .color(.secondary.opacity(0.6)),
            style: StrokeStyle(lineWidth: 1, dash: [4, 4])
        )

        guard let first = points.first else { return }
        var curve = Path()
        curve.move(to: ToneCurveEditorModel.screenPoint(for: first, in: size))
        for point in points.dropFirst() {
            curve.addLine(to: ToneCurveEditorModel.screenPoint(for: point, in: size))
        }
        context.stroke(curve, with: .color(channelColor), lineWidth: 2.5)
    }
}
