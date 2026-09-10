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
                .frame(minHeight: 96, maxHeight: 132)
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
        guard let peak = bins.max(), peak > 0, !bins.isEmpty else { return }
        let stepX = size.width / CGFloat(bins.count)
        var path = Path()
        path.move(to: CGPoint(x: 0, y: size.height))
        for (index, count) in bins.enumerated() {
            let x = CGFloat(index) * stepX
            let y = size.height * (1 - CGFloat(count) / CGFloat(peak))
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        context.fill(path, with: .color(color.opacity(0.42)))
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
}
