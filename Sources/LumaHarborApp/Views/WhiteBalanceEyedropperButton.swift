import EditorCore
import Localization
import SwiftUI

/// Enters/exits the white balance eyedropper tool (design spec §6.4).
/// Mounted next to the "Color" group header, since Kelvin white balance and
/// tint are the two sliders it adjusts (`ColorAdjustmentPanel`'s own doc
/// comment: those two already live in `BasicAdjustmentPanel`, this button
/// doesn't duplicate them, only offers another way to set them). Toggling
/// off while a sample is being previewed cancels it explicitly
/// (`EditorSession.cancelEyedropperPreview()`) rather than leaving it to be
/// silently dropped -- the spec's own "使用者必須能取消滴管" requirement.
struct WhiteBalanceEyedropperButton: View {
    @ObservedObject var editor: EditorSession

    private var isActive: Bool { editor.toolMode == .whiteBalance }

    var body: some View {
        Button {
            if isActive {
                editor.cancelEyedropperPreview()
                editor.setToolMode(.adjust)
            } else {
                editor.setToolMode(.whiteBalance)
            }
        } label: {
            Label(
                isActive ? L10n.t("Cancel Eyedropper") : L10n.t("White Balance Eyedropper"),
                systemImage: "eyedropper"
            )
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .tint(isActive ? Color.accentColor : nil)
        .controlSize(.small)
        .disabled(editor.photo == nil)
        .help(isActive ? L10n.t("Cancel Eyedropper") : L10n.t("White Balance Eyedropper"))
    }
}
