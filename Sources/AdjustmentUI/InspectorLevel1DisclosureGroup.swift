import Localization
import SwiftUI

/// A deterministic first-level inspector section used by both Mac and iPad.
/// The host owns the expansion binding so changing tabs, rotating the iPad,
/// or resizing a Mac window never resets adjustment values or section state.
public struct InspectorLevel1DisclosureGroup<Content: View>: View {
    private let title: String
    private let summary: String?
    @Binding private var isExpanded: Bool
    @ScaledMetric(relativeTo: .headline) private var titleFontSize: CGFloat = InspectorHierarchyMetrics.level1TitleBaseSize
    @ScaledMetric(relativeTo: .caption) private var summaryFontSize: CGFloat = InspectorHierarchyMetrics.level1SummaryBaseSize
    @ViewBuilder private let content: () -> Content

    public init(
        _ title: String,
        summary: String? = nil,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.summary = summary
        self._isExpanded = isExpanded
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: InspectorHierarchyMetrics.level1HeaderSpacing) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: InspectorHierarchyMetrics.level1ChevronSize, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .frame(width: InspectorHierarchyMetrics.level1ChevronColumnWidth, alignment: .center)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: titleFontSize, weight: .semibold))
                        if !isExpanded, let summary {
                            Text(summary)
                                .font(.system(size: summaryFontSize))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                }
                .frame(maxWidth: .infinity, minHeight: InspectorHierarchyMetrics.level1MinRowHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(Text(L10n.t(isExpanded ? "Expanded" : "Collapsed")))

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    content()
                }
                .padding(.top, 8)
                .padding(.leading, InspectorHierarchyMetrics.level1ContentLeadingInset)
            }

            Divider().opacity(0.45)
        }
        .animation(.easeOut(duration: 0.18), value: isExpanded)
    }
}
