import Localization
import RawProcessingCore
import SwiftUI

public enum HistogramDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case rgb
    case luminance

    public var id: Self { self }

    fileprivate var localizationKey: String {
        switch self {
        case .rgb: return "RGB"
        case .luminance: return "Luminance"
        }
    }
}

/// Small, reusable histogram presentation for both the Mac inspector and the
/// iPad Info domain. The data still comes from the rendered preview, while the
/// mode switch and clipping readout make the graph useful during exposure work.
public struct HistogramPanel: View {
    let histogram: HistogramData?
    @State private var mode: HistogramDisplayMode = .rgb

    public init(histogram: HistogramData?) {
        self.histogram = histogram
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(L10n.t("Histogram"), systemImage: "chart.bar.xaxis")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Picker(L10n.t("Histogram"), selection: $mode) {
                    ForEach(HistogramDisplayMode.allCases) { item in
                        Text(L10n.t(item.localizationKey)).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 190)
            }

            if let histogram {
                Canvas { context, size in
                    draw(histogram, mode: mode, in: &context, size: size)
                }
                // Keep the plot area stable in the inspector so a narrow iPad
                // column cannot collapse the Canvas or clip its final bin.
                .frame(minHeight: 96, idealHeight: 132, maxHeight: 132)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel(Text(L10n.t("Histogram")))

                let clipping = HistogramPresentationMetrics.clippingCounts(histogram)
                if clipping.shadows > 0 || clipping.highlights > 0 {
                    HStack(spacing: 12) {
                        if clipping.shadows > 0 {
                            Label("\(L10n.t("Shadows clipped")) \(clipping.shadows)", systemImage: "triangle.fill")
                                .foregroundStyle(.blue)
                        }
                        if clipping.highlights > 0 {
                            Label("\(L10n.t("Highlights clipped")) \(clipping.highlights)", systemImage: "triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.caption2)
                }
            } else {
                Text(L10n.t("No histogram available yet"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 96, alignment: .center)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func draw(
        _ histogram: HistogramData,
        mode: HistogramDisplayMode,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        switch mode {
        case .rgb:
            draw(histogram.red, color: .red, in: &context, size: size)
            draw(histogram.green, color: .green, in: &context, size: size)
            draw(histogram.blue, color: .blue, in: &context, size: size)
        case .luminance:
            draw(HistogramPresentationMetrics.luminanceBins(histogram), color: .white, in: &context, size: size)
        }
    }

    private func draw(
        _ bins: [Int],
        color: Color,
        in context: inout GraphicsContext,
        size: CGSize
    ) {
        guard size.width > 0, size.height > 0 else { return }
        let heights = HistogramPresentationMetrics.displayHeights(for: bins)
        guard !heights.isEmpty else { return }

        let inset = min(CGFloat(1), min(size.width, size.height) / 2)
        let plotWidth = max(size.width - (inset * 2), 0)
        let plotHeight = max(size.height - (inset * 2), 0)
        let denominator = CGFloat(max(heights.count - 1, 1))
        var curve = Path()
        curve.move(to: CGPoint(x: inset, y: size.height - inset))
        for (index, height) in heights.enumerated() {
            let x = inset + plotWidth * CGFloat(index) / denominator
            let y = inset + plotHeight * (1 - height)
            curve.addLine(to: CGPoint(x: x, y: y))
        }
        curve.addLine(to: CGPoint(x: size.width - inset, y: size.height - inset))
        curve.closeSubpath()

        // A translucent fill preserves the familiar histogram look while the
        // contour keeps low-frequency detail visible against a dark canvas.
        context.fill(curve, with: .color(color.opacity(0.28)))

        var outline = Path()
        for (index, height) in heights.enumerated() {
            let x = inset + plotWidth * CGFloat(index) / denominator
            let y = inset + plotHeight * (1 - height)
            if index == 0 {
                outline.move(to: CGPoint(x: x, y: y))
            } else {
                outline.addLine(to: CGPoint(x: x, y: y))
            }
        }
        context.stroke(outline, with: .color(color.opacity(0.82)), lineWidth: 1)
    }
}

public enum HistogramPresentationMetrics {
    public static func luminanceBins(_ histogram: HistogramData) -> [Int] {
        let count = min(histogram.red.count, min(histogram.green.count, histogram.blue.count))
        return (0..<count).map { index in
            let red = Double(histogram.red[index])
            let green = Double(histogram.green[index])
            let blue = Double(histogram.blue[index])
            let weighted = (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
            return Int(weighted)
        }
    }

    public static func clippingCounts(_ histogram: HistogramData) -> (shadows: Int, highlights: Int) {
        guard !histogram.red.isEmpty, !histogram.green.isEmpty, !histogram.blue.isEmpty else {
            return (0, 0)
        }
        let shadows = max(histogram.red[0], max(histogram.green[0], histogram.blue[0]))
        let highlights = max(
            histogram.red[histogram.red.count - 1],
            max(histogram.green[histogram.green.count - 1], histogram.blue[histogram.blue.count - 1])
        )
        return (shadows, highlights)
    }

    /// Returns normalized bar heights suitable for a compact histogram plot.
    ///
    /// RAW previews often contain a large clipped shadow/highlight spike. A
    /// linear `count / max` mapping makes every other tonal region appear flat
    /// in that case, especially in the narrow iPad inspector. Log compression
    /// retains ordering and the peak while keeping those regions readable.
    public static func displayHeights(for bins: [Int]) -> [CGFloat] {
        guard !bins.isEmpty else { return [] }
        let sanitized = bins.map { max($0, 0) }
        guard let peak = sanitized.max(), peak > 0 else {
            return Array(repeating: 0, count: sanitized.count)
        }

        let logPeak = log1p(Double(peak))
        guard logPeak.isFinite, logPeak > 0 else {
            return Array(repeating: 0, count: sanitized.count)
        }
        return sanitized.map { count in
            let normalized = log1p(Double(count)) / logPeak
            return CGFloat(min(max(normalized, 0), 1))
        }
    }
}
