import SwiftUI

private struct AdaptiveWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = AdaptiveRowLayout.stackedWidthThreshold
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Measures its own rendered width via a background `GeometryReader` (rather
/// than wrapping content directly in one, which would collapse the row's
/// height) and hands the raw width to `content`. The single measurement
/// primitive every width-adaptive inspector view builds on, so macOS and
/// iPad react to the same live width rather than each re-implementing this.
struct AdaptiveWidthContainer<Content: View>: View {
    @State private var measuredWidth: CGFloat = AdaptiveRowLayout.stackedWidthThreshold
    @ViewBuilder let content: (CGFloat) -> Content

    var body: some View {
        content(measuredWidth)
            .background(
                GeometryReader { geometry in
                    Color.clear.preference(key: AdaptiveWidthKey.self, value: geometry.size.width)
                }
            )
            .onPreferenceChange(AdaptiveWidthKey.self) { measuredWidth = $0 }
    }
}

/// Hands the resulting `AdjustmentRowComposition` (`AdaptiveRowLayout`) to
/// `content` instead of a raw width -- what every adjustment row (label +
/// numeric controls + slider) switches its layout on.
struct AdaptiveRowContainer<Content: View>: View {
    @ViewBuilder let content: (AdjustmentRowComposition) -> Content

    var body: some View {
        AdaptiveWidthContainer { width in
            content(AdaptiveRowLayout.composition(forAvailableWidth: width))
        }
    }
}
