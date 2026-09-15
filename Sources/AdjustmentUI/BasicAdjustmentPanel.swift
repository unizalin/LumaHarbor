import EditorCore
import Localization
import RawProcessingCore
import SwiftUI

/// The ten basic adjustments, usable in a Mac inspector or an iPad editing surface.
public struct BasicAdjustmentPanel: View {
    @ObservedObject private var editor: EditorSession
    private let kinds: [AdjustmentKind]

    public init(editor: EditorSession, kinds: [AdjustmentKind]? = nil) {
        self.editor = editor
        self.kinds = kinds ?? AdjustmentCatalog.ordered.map(\.kind)
    }

    public var body: some View {
        ForEach(BasicAdjustmentPanelModel.rows, id: \.kind) { definition in
            if kinds.contains(definition.kind) {
                row(definition)
            }
        }
    }

    /// Built on the shared `AdjustmentSliderRow` (inspector hierarchy/preview
    /// spec §5.6, §5.4): the numeric field's nudge/typed entry stays a
    /// discrete, immediate commit via `setAdjustment(_:to:)`, while the
    /// slider drag previews through `previewContinuousEdit`/
    /// `commitContinuousEdit` so a whole drag becomes exactly one Undo entry
    /// and one autosave, and the row adopts the same adaptive width
    /// composition every other continuous control uses.
    private func row(_ definition: AdjustmentDefinition) -> some View {
        AdjustmentSliderRow(
            label: definition.kind.displayName,
            value: editor.displayedAdjustments[definition.kind],
            range: definition.range,
            fractionDigits: definition.fractionDigits,
            step: definition.step,
            onChange: { editor.setAdjustment(definition.kind, to: $0) },
            onReset: { editor.resetAdjustment(definition.kind) },
            onEditingChanged: { isEditing in
                if isEditing {
                    editor.beginAdjustmentGesture()
                } else {
                    editor.endAdjustmentGesture()
                }
            },
            onPreview: { newValue in
                editor.previewContinuousEdit { $0[definition.kind] = newValue }
            },
            onCommitPreview: { editor.commitContinuousEdit() }
        )
    }

}
