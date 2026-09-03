import EditorCore
import Localization
import RawProcessingCore
import SwiftUI

/// Crop, rotate, flip, straighten (design spec §6.5, "Geometry" — new for
/// Phase 2, not one of §6.3's Basic/Color/Curve/Detail/Effects groups).
/// Rotate/flip/straighten write straight through `EditorSession
/// .updateAdjustments(_:)`, the same undo/autosave path every other
/// adjustment uses; "Edit Crop" instead flips `EditorSession.toolMode` to
/// `.crop`, which arms `CropOverlayView` on the photo itself -- dragging the
/// crop rect is a canvas gesture, not a slider, so it has no row here of its
/// own.
public struct GeometryAdjustmentPanel: View {
    @ObservedObject private var editor: EditorSession

    public init(editor: EditorSession) {
        self.editor = editor
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DisclosureGroup(L10n.t("Rotate & Flip")) {
                HStack(spacing: 16) {
                    Button {
                        editor.updateAdjustments { $0.geometry = $0.geometry.rotatedCounterclockwise() }
                    } label: {
                        Label(L10n.t("Rotate Left"), systemImage: "rotate.left")
                    }
                    .help(L10n.t("Rotate Left"))

                    Button {
                        editor.updateAdjustments { $0.geometry = $0.geometry.rotatedClockwise() }
                    } label: {
                        Label(L10n.t("Rotate Right"), systemImage: "rotate.right")
                    }
                    .help(L10n.t("Rotate Right"))

                    Button {
                        editor.updateAdjustments { $0.geometry = $0.geometry.flippingHorizontal() }
                    } label: {
                        Label(L10n.t("Flip Horizontal"), systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    }
                    .help(L10n.t("Flip Horizontal"))

                    Button {
                        editor.updateAdjustments { $0.geometry = $0.geometry.flippingVertical() }
                    } label: {
                        Label(L10n.t("Flip Vertical"), systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                    }
                    .help(L10n.t("Flip Vertical"))
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
            }

            DisclosureGroup(L10n.t("Straighten")) {
                AdjustmentSliderRow(
                    label: L10n.t("Straighten"),
                    value: editor.adjustments.geometry.straightenDegrees,
                    range: GeometryAdjustments.straightenRange,
                    fractionDigits: 1,
                    onChange: { newValue in editor.updateAdjustments { $0.geometry.straightenDegrees = newValue } },
                    onReset: { editor.updateAdjustments { $0.geometry = $0.geometry.resettingStraighten() } }
                )
            }

            DisclosureGroup(L10n.t("Crop")) {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        editor.setToolMode(editor.toolMode == .crop ? .adjust : .crop)
                    } label: {
                        Text(editor.toolMode == .crop ? L10n.t("Done") : L10n.t("Edit Crop"))
                            .frame(maxWidth: .infinity)
                    }

                    // Records the lock the user wants; the overlay
                    // enforcing it during a drag (rather than only when a
                    // preset value is picked) is a follow-up, not this
                    // foundation round's scope.
                    Picker(L10n.t("Aspect Ratio"), selection: aspectRatioBinding) {
                        Text(L10n.t("Freeform")).tag(CropAspectRatio.freeform)
                        Text(L10n.t("Original")).tag(CropAspectRatio.original)
                        Text(L10n.t("Square")).tag(CropAspectRatio.square)
                    }
                    .pickerStyle(.menu)

                    Button(L10n.t("Reset Crop")) {
                        editor.updateAdjustments { $0.geometry = $0.geometry.resettingCrop() }
                    }
                    .controlSize(.small)
                    .disabled(editor.adjustments.geometry.crop == nil)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("Geometry adjustments are non-destructive."))
                Text(L10n.t("Your RAW original was not changed."))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Button(L10n.t("Reset")) {
                editor.updateAdjustments { $0.geometry = .neutral }
            }
            .controlSize(.small)
            .disabled(editor.adjustments.geometry.isIdentity)
        }
    }

    private var aspectRatioBinding: Binding<CropAspectRatio> {
        Binding(
            get: { editor.adjustments.geometry.cropAspectRatio },
            set: { newValue in editor.updateAdjustments { $0.geometry.cropAspectRatio = newValue } }
        )
    }
}
