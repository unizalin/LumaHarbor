import EditorCore
import Localization
import RawProcessingCore
import SwiftUI

/// The channel selector is a presentation control for the shared advanced
/// tone curve. The current sidecar format stores one composite curve, so every
/// channel uses the same persisted points while retaining familiar RGB editing
/// affordances for the iPad and Mac surfaces.
public enum ToneCurveChannel: String, CaseIterable, Identifiable, Sendable {
    case rgb
    case red
    case green
    case blue

    public var id: Self { self }

    var localizationKey: String {
        switch self {
        case .rgb: return "RGB"
        case .red: return "Red"
        case .green: return "Green"
        case .blue: return "Blue"
        }
    }
}

/// Pure geometry and clamping helpers for the draggable tone curve.
public enum ToneCurveEditorModel {
    public static func points(for curve: AdvancedToneCurve) -> [ToneCurvePoint] {
        guard !curve.isIdentity, curve.points.count >= 2 else {
            return ToneCurveMapping.identity
        }
        return curve.points
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
        in size: CGSize
    ) -> Int? {
        guard !points.isEmpty, size.width > 0, size.height > 0 else { return nil }
        return points.indices.min { lhs, rhs in
            distanceSquared(screenPoint(for: points[lhs], in: size), location)
                < distanceSquared(screenPoint(for: points[rhs], in: size), location)
        }
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
    @State private var selectedChannel: ToneCurveChannel = .rgb

    public init(editor: EditorSession) {
        self.editor = editor
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(L10n.t("Tone curve"), systemImage: "chart.xyaxis.line")
                    .font(.headline)
                Spacer()
                Button(L10n.t("Reset")) {
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
                points: ToneCurveEditorModel.points(for: editor.adjustments.advancedToneCurve),
                channel: selectedChannel,
                onChange: { points in
                    editor.updateAdjustments { $0.advancedToneCurve = AdvancedToneCurve(points: points) }
                },
                onGesture: { isEditing in
                    if isEditing {
                        editor.beginAdjustmentGesture()
                    } else {
                        editor.endAdjustmentGesture()
                    }
                }
            )
            .frame(minHeight: 170, maxHeight: 230)
            .accessibilityElement(children: .contain)

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
        if curve.isIdentity {
            return L10n.t("No curve applied")
        }
        return String(format: L10n.t("%d control points"), curve.points.count)
    }
}

private struct ToneCurveGraph: View {
    let points: [ToneCurvePoint]
    let channel: ToneCurveChannel
    let onChange: ([ToneCurvePoint]) -> Void
    let onGesture: (Bool) -> Void

    @State private var draggingIndex: Int?
    @State private var isEditing = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Canvas { context, size in
                    drawGrid(in: &context, size: size)
                }

                ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                    Circle()
                        .fill(channelColor)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1.5))
                        .position(ToneCurveEditorModel.screenPoint(for: point, in: proxy.size))
                        .allowsHitTesting(false)
                }
            }
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if draggingIndex == nil {
                            draggingIndex = ToneCurveEditorModel.nearestPointIndex(
                                in: points,
                                to: value.startLocation,
                                in: proxy.size
                            )
                        }
                        guard let index = draggingIndex else { return }
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
                    .onEnded { _ in
                        draggingIndex = nil
                        if isEditing {
                            isEditing = false
                            onGesture(false)
                        }
                    }
            )
            .accessibilityLabel(Text(L10n.t("Tone curve")))
            .accessibilityValue(Text(L10n.t(channel.localizationKey)))
        }
    }

    private var channelColor: Color {
        switch channel {
        case .rgb: return .accentColor
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
