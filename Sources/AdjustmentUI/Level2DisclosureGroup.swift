import Localization
import SwiftUI

public enum InspectorHierarchyMetrics {
    public static let level1Inset: CGFloat = 0
    public static let level2Inset: CGFloat = 16
    public static let level3RelativeInset: CGFloat = 10
    public static let level3Inset = level2Inset + level3RelativeInset
    public static let level2ChevronSize: CGFloat = 9

    /// Level 1's own chevron column width and header spacing, expressed as
    /// fixed layout constants rather than left to a glyph's natural (and
    /// font/OS-version-dependent) bounding box. A 2026-09-14 user acceptance
    /// pass found that a Level 1 host built on the native `DisclosureGroup`
    /// never produced a visible 16pt gap between the group title and its
    /// expanded content, because that native control's own content
    /// indentation is opaque platform behavior the app does not control --
    /// bumping `level2Inset` alone changed nothing on screen. The Level 1
    /// host now builds its own header (mirroring `Level2DisclosureGroup`
    /// below) using these two fixed values, so `level1TitleLeadingOffset`
    /// is an exact, known quantity: the title text always starts at
    /// `level1ChevronColumnWidth + level1HeaderSpacing` from the row's own
    /// leading edge, regardless of the chevron glyph's rendered metrics.
    public static let level1ChevronSize: CGFloat = 11
    public static let level1ChevronColumnWidth: CGFloat = 16
    /// The gap between the disclosure column and the title is deliberately
    /// larger than the nested row gap so the first-level hierarchy remains
    /// legible in a dense bottom drawer and in a narrow Split View.
    public static let level1HeaderSpacing: CGFloat = 12
    public static let level1TitleLeadingOffset: CGFloat = level1ChevronColumnWidth + level1HeaderSpacing

    /// The Level 1 host's expanded-content leading padding, measured from
    /// the row's own leading edge (same baseline as the chevron). Because
    /// `level1TitleLeadingOffset` is exact, this constant guarantees the
    /// *content text* starts exactly `level2Inset` to the right of the
    /// *title text* -- the comparison a user actually sees on screen --
    /// rather than a gap measured from an unrelated origin.
    public static let level1ContentLeadingInset: CGFloat = level1TitleLeadingOffset + level2Inset

    /// Minimum header row height, and the actions menu's own independent
    /// hit-target size, per the inspector hierarchy spec's touch/pointer
    /// target requirements.
    public static let level1MinRowHeight: CGFloat = 44

    /// Level 2 headings are full-width controls on iPad, not just the height
    /// of their glyphs. macOS keeps a denser pointer-oriented row while the
    /// shared hierarchy still guarantees a comfortable touch target on iPad.
    public static var level2MinRowHeight: CGFloat {
        #if os(iOS)
        44
        #else
        32
        #endif
    }

    /// Cross-platform Level 1 title size. Both hosts use the same hierarchy;
    /// `@ScaledMetric` still lets macOS and iPadOS honor the user's text-size
    /// setting instead of treating this as an unscaled literal.
    public static let level1TitleBaseSize: CGFloat = 18

    /// Cross-platform Level 2 title size. It remains below Level 1 while
    /// staying stronger than ordinary adjustment labels.
    public static let level2TitleBaseSize: CGFloat = 16

    /// Collapsed-group summary size, kept readable without competing with the
    /// section title.
    public static let level1SummaryBaseSize: CGFloat = 13

    // Compatibility aliases for the existing Mac contract/tests. The values
    // are shared now; the aliases remain so downstream callers do not need a
    // coordinated rename.
    public static let level1MacTitleBaseSize = level1TitleBaseSize
    public static let level2MacTitleBaseSize = level2TitleBaseSize
    public static let level1MacSummaryBaseSize = level1SummaryBaseSize
}

/// Pure expansion-state rules shared by the Mac and iPad inspector hosts.
/// Keeping the policy outside a view makes the default and toggle behavior
/// testable without a SwiftUI renderer.
public enum InspectorSectionExpansionPolicy {
    public static let initialExpanded: Set<InspectorSectionID> = [.basic]

    public static func toggled(
        _ section: InspectorSectionID,
        in expanded: Set<InspectorSectionID>
    ) -> Set<InspectorSectionID> {
        var next = expanded
        if next.contains(section) {
            next.remove(section)
        } else {
            next.insert(section)
        }
        return next
    }
}

/// A non-collapsible Level 2 subsection. Compact subsections such as White
/// Balance still need the same cumulative hierarchy as collapsible sections,
/// but do not benefit from adding another disclosure interaction.
public struct Level2Section<Trailing: View, Content: View>: View {
    private let title: String
    @ScaledMetric(relativeTo: .subheadline) private var titleFontSize: CGFloat = InspectorHierarchyMetrics.level2TitleBaseSize
    @ViewBuilder private let trailing: () -> Trailing
    @ViewBuilder private let content: () -> Content

    public init(
        _ title: String,
        @ViewBuilder trailing: @escaping () -> Trailing,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.trailing = trailing
        self.content = content
    }

    public var body: some View {
        // The Level 1 group that hosts this subsection (`InspectorView
        // .inspectorGroup`) already applies the Level 2 cumulative inset to
        // its whole expanded-content container, so this view only adds the
        // *relative* remainder needed to reach the Level 3 cumulative inset
        // -- it must not re-apply `level2Inset` itself, or the header would
        // double-indent to 32pt instead of the spec's 12-16pt.
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: titleFontSize, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                trailing()
            }
            .frame(maxWidth: .infinity, minHeight: InspectorHierarchyMetrics.level2MinRowHeight, alignment: .leading)
            .contentShape(Rectangle())

            VStack(alignment: .leading, spacing: 6) {
                content()
            }
            .padding(.leading, InspectorHierarchyMetrics.level3RelativeInset)

            Divider().opacity(0.4)
        }
    }
}

public extension Level2Section where Trailing == EmptyView {
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(title, trailing: { EmptyView() }, content: content)
    }
}

/// A Level 2 subsection disclosure (inspector hierarchy/typography spec
/// §5.1's hierarchy table: White Balance, HSL, Black and White, Sharpening,
/// Noise Reduction, ...). Deliberately a custom, smaller disclosure rather
/// than a second native `DisclosureGroup` -- the spec requires every nested
/// level to be visually distinct from its Level 1 parent in leading inset,
/// type weight, divider strength, *and* chevron size, which a native
/// `DisclosureGroup` (whose chevron always matches the platform's own fixed
/// size) cannot express next to another native `DisclosureGroup`.
public struct Level2DisclosureGroup<Content: View>: View {
    private let titleKey: String
    @State private var isExpanded: Bool
    @ScaledMetric(relativeTo: .subheadline) private var titleFontSize: CGFloat = InspectorHierarchyMetrics.level2TitleBaseSize
    @ViewBuilder private let content: () -> Content

    public init(_ titleKey: String, initiallyExpanded: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.titleKey = titleKey
        self._isExpanded = State(initialValue: initiallyExpanded)
        self.content = content
    }

    public var body: some View {
        // As in `Level2Section` above, the Level 1 host already supplies the
        // Level 2 cumulative inset for this whole subsection (header and
        // content alike); only the extra relative step down to Level 3 is
        // added here, so this view must not add `level2Inset` a second time.
        VStack(alignment: .leading, spacing: 6) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: InspectorHierarchyMetrics.level2ChevronSize, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                    Text(titleKey)
                        .font(.system(size: titleFontSize, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: InspectorHierarchyMetrics.level2MinRowHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(Text(L10n.t(isExpanded ? "Expanded" : "Collapsed")))

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    content()
                }
                // Level 3 relative inset on top of the Level 2 inset the
                // Level 1 host already applied (cumulative total: spec's
                // 24-28pt "from inspector content").
                .padding(.leading, InspectorHierarchyMetrics.level3RelativeInset)
                Divider().opacity(0.4)
            }
        }
    }
}
