import EditorCore
import Localization
import RawProcessingCore
import SwiftUI

/// Shared provenance panel used by the Mac and iPad Info pages. It is
/// observational: rendering values are owned by EditorSession and this view
/// never changes the recipe or adjustment state.
public struct RawRenderDiagnosticsPanel: View {
    private let recipe: ResolvedRawRenderRecipe?
    @ScaledMetric(relativeTo: .caption) private var labelWidth: CGFloat = 132

    public init(recipe: ResolvedRawRenderRecipe?) {
        self.recipe = recipe
    }

    public var body: some View {
        if let recipe {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.t("Render Diagnostics"))
                    .font(.subheadline.weight(.semibold))
                ForEach(RawRenderDiagnosticsPresenter.rows(for: recipe)) { row in
                    HStack(alignment: .top, spacing: 8) {
                        Text(L10n.t(row.labelKey))
                            .foregroundStyle(.secondary)
                            .frame(width: labelWidth, alignment: .leading)
                        Text(row.displayValue)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .font(.caption)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(row.identifier)
                }
            }
            .accessibilityElement(children: .contain)
        }
    }
}
