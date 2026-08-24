import EditorCore
import Localization
import RawProcessingCore
import SwiftUI

/// The ten basic adjustments, usable in a Mac inspector or an iPad editing surface.
public struct BasicAdjustmentPanel: View {
    @ObservedObject private var editor: EditorSession

    public init(editor: EditorSession) {
        self.editor = editor
    }

    public var body: some View {
        ForEach(AdjustmentGroup.allCases, id: \.self) { group in
            Section(group.displayName) {
                ForEach(AdjustmentCatalog.definitions(in: group), id: \.kind) { definition in
                    row(definition)
                }
            }
        }
    }

    private func row(_ definition: AdjustmentDefinition) -> some View {
        macOSResetGesture(
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(definition.kind.displayName)
                    Spacer()
                    Text(BasicAdjustmentPanelModel.formatted(
                        editor.adjustments[definition.kind],
                        fractionDigits: definition.fractionDigits
                    ))
                    .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { editor.adjustments[definition.kind] },
                        set: { editor.setAdjustment(definition.kind, to: $0) }
                    ),
                    in: definition.range
                )
                .accessibilityLabel(Text(definition.kind.displayName))
                .accessibilityValue(Text(BasicAdjustmentPanelModel.formatted(
                    editor.adjustments[definition.kind],
                    fractionDigits: definition.fractionDigits
                )))
            }
            .contextMenu {
                Button("\(L10n.t("Reset")) \(definition.kind.displayName)") {
                    editor.resetAdjustment(definition.kind)
                }
            },
            definition: definition
        )
    }

    private func macOSResetGesture<Content: View>(
        _ content: Content,
        definition: AdjustmentDefinition
    ) -> some View {
        #if os(macOS)
        content
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                editor.resetAdjustment(definition.kind)
            }
            .help(L10n.t("Double-click the row to reset"))
        #else
        content
        #endif
    }
}
