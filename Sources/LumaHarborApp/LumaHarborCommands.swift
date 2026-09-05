import SwiftUI
import Localization

/// macOS menu bar and keyboard shortcuts (spec §4: AppKit-backed capabilities
/// where SwiftUI alone isn't enough).
struct LumaHarborCommands: Commands {
    @ObservedObject var model: LibraryViewModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(L10n.t("Add Photo Folder…")) {
                model.presentAddFolderPanel()
            }
            .keyboardShortcut("o", modifiers: .command)
        }

        // `.undoRedo` is deliberately left unreplaced: SwiftUI's own system
        // Undo/Redo menu items carry the OS-standard ⌘Z/⌘⇧Z key equivalents
        // and dispatch `undo:`/`redo:` through the real first-responder
        // chain, which is what `LumaHarborAppDelegate` in
        // `LumaHarborMainApp.swift` implements those selectors for. Two
        // earlier attempts at a custom `CommandGroup(replacing: .undoRedo)`
        // (with an explicit `.keyboardShortcut`, then backed by a local
        // `NSEvent` key-down monitor instead) both failed real-hardware
        // testing -- see the doc comment on `LumaHarborAppDelegate`.

        CommandGroup(replacing: .saveItem) {
            Button(L10n.t("Save Adjustments")) {
                Task { await model.editor.save() }
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(model.editor.photo == nil)

            Button(L10n.t("Export JPEG…")) {
                model.isShowingExportSheet = true
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(model.selectedPhotoID == nil)
        }

        CommandMenu(L10n.t("Photo")) {
            Button(L10n.t("Next Photo")) { model.selectNextPhoto() }
                .keyboardShortcut("]", modifiers: .command)
            Button(L10n.t("Previous Photo")) { model.selectPreviousPhoto() }
                .keyboardShortcut("[", modifiers: .command)

            Divider()

            Button(L10n.t("Show Original")) {
                model.editor.isShowingOriginal.toggle()
            }
            .keyboardShortcut("\\", modifiers: [])
            .disabled(!model.editor.canCompareWithOriginal)

            Button(L10n.t("Reset All Adjustments")) { model.editor.resetAll() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.editor.photo == nil || !model.editor.hasEdits)

            // Phase 3 Task 3.4: compound batch undo -- reverts the most
            // recent batch sync (a drag or reset on the ten basic sliders
            // that landed on at least one other selected photo) as one
            // step, distinct from the per-photo Undo above, which only ever
            // touches the currently-open photo's own history.
            Button(L10n.t("Undo Batch Sync")) {
                Task {
                    guard let summary = await model.undoLastBatchTransaction() else { return }
                    model.alert = UserAlert(
                        title: L10n.t("Batch Sync Undone"),
                        message: LibraryViewModel.batchUndoSummaryMessage(summary)
                    )
                }
            }
            .disabled(model.lastBatchTransaction == nil)

            Divider()

            Button(L10n.t("Rescan Folder")) { model.startScan() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!(model.selectedLibrary?.isOnline ?? false))
        }
    }
}
