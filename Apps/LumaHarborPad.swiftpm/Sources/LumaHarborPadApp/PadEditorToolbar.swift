import AdjustmentUI
import EditorCore
import Localization
import PresetCore
import SwiftUI

/// The document toolbar is kept separate from the editor root so toolbar
/// actions remain identical when the canvas and Inspector containers adapt.
struct PadEditorToolbar: ToolbarContent {
    @ObservedObject var model: PadEditorModel
    @ObservedObject var editor: EditorSession
    @ObservedObject var batchCoordinator: PadBatchAdjustmentCoordinator
    let exportedURL: URL?
    let selectedPhotoCount: Int
    @Binding var isExporting: Bool
    @Binding var isPresentingExportOptions: Bool
    @Binding var isPresentingFileExporter: Bool
    @Binding var isSavingToPhotos: Bool
    @Binding var adjustmentClipboard: PadAdjustmentClipboard?
    @Binding var clipboardFields: Set<AdjustmentFieldID>
    @Binding var copyIncludesGeometry: Bool
    @Binding var copyIncludesLocalAdjustments: Bool
    let onClose: () -> Void
    let onPresentInspector: () -> Void
    let onSaveToPhotos: (URL) -> Void
    let onBatchMessage: (String) -> Void

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(L10n.t("Close"), action: onClose)
                .disabled(model.isPreparingDocument)
        }
        ToolbarItem(placement: .primaryAction) {
            Button(action: onPresentInspector) {
                Label(L10n.t("Adjustments"), systemImage: "slider.horizontal.3")
            }
            .accessibilityLabel(Text(L10n.t("Adjustments")))
            .accessibilityHint(Text(L10n.t("Show Inspector")))
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                isPresentingExportOptions = true
            } label: {
                if isExporting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label(L10n.t("Export"), systemImage: "square.and.arrow.up")
                }
            }
            .disabled(isExporting || model.document == nil)
            .accessibilityLabel(Text(L10n.t("Export")))

            if let exportedURL {
                ShareLink(item: exportedURL) {
                    Label(L10n.t("Share"), systemImage: "square.and.arrow.up.on.square")
                }
                .accessibilityLabel(Text(L10n.t("Share exported photo")))

                Button {
                    onSaveToPhotos(exportedURL)
                } label: {
                    if isSavingToPhotos {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label(L10n.t("Save to Photos"), systemImage: "photo.badge.plus")
                    }
                }
                .disabled(isSavingToPhotos)

                Button {
                    isPresentingFileExporter = true
                } label: {
                    Label(L10n.t("Save to Files"), systemImage: "folder")
                }
                .accessibilityLabel(Text(L10n.t("Save to Files")))
            }

            compareMenu
            adjustmentClipboardMenu
        }
    }

    private var compareMenu: some View {
        Menu {
            Button {
                editor.setCompareMode(.single)
            } label: {
                Label(L10n.t("Single View"), systemImage: "rectangle")
            }
            .disabled(editor.compareMode == .single)

            Button {
                editor.setCompareMode(.sideBySide)
            } label: {
                Label(L10n.t("Side by Side"), systemImage: "rectangle.split.2x1")
            }
            .disabled(!editor.canCompareWithOriginal)

            Button {
                editor.setCompareMode(.verticalWipe)
            } label: {
                Label(L10n.t("Wipe"), systemImage: "rectangle.split.2x1.fill")
            }
            .disabled(!editor.canCompareWithOriginal)

            Divider()

            Toggle(isOn: $editor.isShowingOriginal) {
                Label(L10n.t("Hold Before"), systemImage: "eye")
            }
            .disabled(editor.compareMode != .single || !editor.canCompareWithOriginal)

            if !editor.snapshots.isEmpty {
                Divider()
                Menu(L10n.t("Compare with Snapshot")) {
                    ForEach(editor.snapshots) { snap in
                        Button {
                            if editor.comparisonSnapshot?.id == snap.id {
                                editor.comparisonSnapshot = nil
                            } else {
                                editor.comparisonSnapshot = snap
                            }
                        } label: {
                            HStack {
                                Text(snap.name)
                                if editor.comparisonSnapshot?.id == snap.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                    if editor.comparisonSnapshot != nil {
                        Divider()
                        Button(L10n.t("Exit Compare")) {
                            editor.comparisonSnapshot = nil
                        }
                    }
                }
            }
        } label: {
            Label(L10n.t("Compare Mode"), systemImage: "rectangle.on.rectangle")
        }
        .accessibilityLabel(Text(L10n.t("Compare")))
    }

    private var adjustmentClipboardMenu: some View {
        Menu {
            Toggle(L10n.t("Include Geometry"), isOn: $copyIncludesGeometry)
            Toggle(L10n.t("Include Local Adjustments"), isOn: $copyIncludesLocalAdjustments)

            Divider()

            Button {
                adjustmentClipboard = PadAdjustmentClipboard.copying(
                    from: editor.adjustments,
                    fields: clipboardFields,
                    includeGeometry: copyIncludesGeometry,
                    includeLocalAdjustments: copyIncludesLocalAdjustments
                )
            } label: {
                Label(L10n.t("Copy Adjustments"), systemImage: "doc.on.doc")
            }
            .disabled(editor.photo == nil || clipboardFields.isEmpty)

            Button {
                guard let adjustmentClipboard else { return }
                editor.pasteAdjustments(
                    patch: adjustmentClipboard.patch,
                    geometry: adjustmentClipboard.geometry,
                    localAdjustments: adjustmentClipboard.localAdjustments
                )
            } label: {
                Label(L10n.t("Paste Adjustments"), systemImage: "doc.on.clipboard")
            }
            .disabled(editor.photo == nil || adjustmentClipboard == nil)

            Button {
                Task {
                    let transaction = await batchCoordinator.sync(
                        adjustmentClipboard,
                        sourcePhotoID: editor.photo?.id
                    )
                    guard let transaction else {
                        onBatchMessage(L10n.t("Nothing to sync."))
                        return
                    }
                    onBatchMessage(PadBatchAdjustmentCoordinator.summaryMessage(transaction))
                }
            } label: {
                Label(L10n.t("Sync to Selected Photos"), systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(editor.photo == nil || adjustmentClipboard == nil || selectedPhotoCount < 2)

            Button {
                Task {
                    guard let summary = await batchCoordinator.undoLastTransaction() else { return }
                    onBatchMessage(PadBatchAdjustmentCoordinator.undoSummaryMessage(summary))
                }
            } label: {
                Label(L10n.t("Undo Batch Sync"), systemImage: "arrow.uturn.backward")
            }
            .disabled(batchCoordinator.lastTransaction == nil)
        } label: {
            Image(systemName: "slider.horizontal.2.square")
        }
        .accessibilityLabel(Text(L10n.t("Copy Adjustments")))
    }
}
