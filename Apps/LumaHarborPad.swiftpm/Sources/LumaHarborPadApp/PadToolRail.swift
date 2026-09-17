import AdjustmentUI
import Localization
import SwiftUI

/// button. Axis-agnostic: `.vertical` for the leading-edge rail in work mode,
/// `.horizontal` for a compact domain bar. Carries no local state.
/// A five-item tool rail that exposes every `PadInspectorDomain` as a tappable
/// button. Axis-agnostic: `.vertical` for the leading-edge rail in work mode,
/// `.horizontal` for a compact domain bar. Carries no local state.
/// button. Axis-agnostic: `.vertical` for the leading-edge rail in work mode,
/// `.horizontal` for a compact domain bar. Carries no local state.
struct PadToolRail: View {
    @Binding var selection: PadInspectorDomain
    var axis: Axis = .vertical

    private struct RailItem: Identifiable {
        let id: PadInspectorDomain
        let symbol: String
        let labelKey: String
    }

    private static let items: [RailItem] = [
        RailItem(id: .adjust,   symbol: "slider.horizontal.3", labelKey: "Adjustments"),
        RailItem(id: .preset,   symbol: "sparkles",            labelKey: "Presets"),
        RailItem(id: .geometry, symbol: "crop.rotate",         labelKey: "Geometry"),
        RailItem(id: .local,    symbol: "paintbrush.pointed",  labelKey: "Local Adjustments"),
        RailItem(id: .info,     symbol: "info.circle",         labelKey: "Info"),
    ]

    var body: some View {
        Group {
            if axis == .vertical {
                VStack(spacing: 0) {
                    ForEach(Self.items) { item in railButton(item) }
                    Spacer()
                }
            } else {
                HStack(spacing: 0) {
                    ForEach(Self.items) { item in railButton(item) }
                }
            }
        }
        .padding(axis == .vertical ? .vertical : .horizontal, 8)
        // Keep the rendered rail, including its horizontal padding, inside
        // the 88pt budget used by PadEditorLayoutPolicy.
        .frame(width: axis == .vertical ? 88 : nil)
        .background(.thickMaterial)
    }

    private func railButton(_ item: RailItem) -> some View {
        let isSelected = selection == item.id
        return Button {
            selection = item.id
        } label: {
            VStack(spacing: 2) {
                Image(systemName: item.symbol)
                    .imageScale(.small)
                Text(L10n.t(item.labelKey))
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)
            }
            .frame(minWidth: 64, minHeight: 44)
            // Keep the whole stable rail cell tappable, including the
            // wrapped-label area in portrait and Split View layouts.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        .background(
            isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .padding(axis == .vertical ? .horizontal : .vertical, 4)
        .accessibilityLabel(Text(L10n.t(item.labelKey)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
