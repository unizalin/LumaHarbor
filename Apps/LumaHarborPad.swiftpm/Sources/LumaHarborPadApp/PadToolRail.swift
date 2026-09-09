import AdjustmentUI
import Localization
import SwiftUI

/// A five-item tool rail that exposes every `PadInspectorDomain` as a tappable
/// button.  The rail is axis-agnostic: pass `.vertical` for Expanded/Wide
/// profiles where it sits on the leading edge of the canvas, or `.horizontal`
/// for Compact/Standard profiles where it appears as a bottom domain bar.
///
/// Selection is owned entirely by the caller through `selection`; this view
/// carries no local state and never calls `EditorSession`.
struct PadToolRail: View {

    // MARK: - Public interface

    @Binding var selection: PadInspectorDomain

    /// Layout axis.  `.vertical` stacks buttons in a column; `.horizontal`
    /// arranges them in a row.  The caller decides which to use based on its
    /// size class or geometry — this view never inspects device name or orientation.
    var axis: Axis = .vertical

    // MARK: - Private model

    private struct RailItem: Identifiable {
        let id: PadInspectorDomain
        let symbol: String
        let labelKey: String
    }

    private static let items: [RailItem] = [
        RailItem(id: .adjust,   symbol: "slider.horizontal.3", labelKey: "Adjust"),
        RailItem(id: .preset,   symbol: "sparkles",            labelKey: "Presets"),
        RailItem(id: .geometry, symbol: "crop.rotate",         labelKey: "Geometry"),
        RailItem(id: .local,    symbol: "paintbrush.pointed",  labelKey: "Local"),
        RailItem(id: .info,     symbol: "info.circle",         labelKey: "Info"),
    ]

    // MARK: - Body

    var body: some View {
        Group {
            if axis == .vertical {
                VStack(spacing: 0) {
                    ForEach(Self.items) { item in railButton(item) }
                    Spacer()
                }
                .frame(width: 52)
            } else {
                HStack(spacing: 0) {
                    ForEach(Self.items) { item in railButton(item) }
                }
            }
        }
        .padding(axis == .vertical ? .vertical : .horizontal, 8)
        .background(.thickMaterial)
    }

    // MARK: - Button factory

    private func railButton(_ item: RailItem) -> some View {
        let isSelected = selection == item.id
        return Button {
            selection = item.id
        } label: {
            Image(systemName: item.symbol)
                .imageScale(.medium)
                .frame(width: 44, height: 44)
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
