import Localization
import SwiftUI

/// The adaptive color-band selector (inspector hierarchy/typography spec
/// §5.2): a grid of swatches, four columns at 340pt+ and two below it, each
/// showing a color swatch plus the complete localized band name. Shared by
/// the HSL and black-and-white mixers so neither keeps its own stack of
/// eight nested `DisclosureGroup`s. Selecting a band is pure UI state --
/// this view never touches `EditorSession`.
struct HSLBandGridSelector: View {
    @Binding var selection: HSLBandID
    let isModified: (HSLBandID) -> Bool

    /// Minimum item height (spec §5.2: "32 points on macOS and 44 points on
    /// iPad").
    private static var minimumItemHeight: CGFloat {
        #if os(iOS)
        44
        #else
        32
        #endif
    }

    var body: some View {
        AdaptiveWidthContainer { width in
            let columns = Array(
                repeating: GridItem(.flexible(), spacing: 8),
                count: HSLBandSelectorModel.columnCount(forAvailableWidth: width)
            )
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(HSLBandSelectorModel.allBands) { band in
                    swatchButton(for: band)
                }
            }
        }
    }

    private func swatchButton(for band: HSLBandID) -> some View {
        let isSelected = selection == band
        return Button {
            selection = band
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(band.displayColor)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 1))
                Text(L10n.t(band.labelKey))
                    .font(.callout)
                    // Four columns at 340pt leave each cell intentionally
                    // compact. Let the full localized name wrap to two lines
                    // instead of silently replacing it with an ellipsis.
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                if isModified(band) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 8)
            .frame(minHeight: Self.minimumItemHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(L10n.t(band.labelKey)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(Text(isModified(band) ? L10n.t("Modified") : L10n.t("Neutral")))
    }
}

extension HSLBandID {
    /// Approximate hue swatch for the grid -- purely a visual aid, never
    /// used as the sole way to communicate selection (spec §5.2:
    /// "distinguishable without color alone").
    var displayColor: Color {
        switch self {
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .aqua: return .cyan
        case .blue: return .blue
        case .purple: return .purple
        case .magenta: return Color(red: 0.85, green: 0.15, blue: 0.65)
        }
    }
}
