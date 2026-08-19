import SwiftUI

/// macOS menu bar and keyboard shortcuts (spec §4: AppKit-backed capabilities
/// where SwiftUI alone isn't enough).
struct LumaHarborCommands: Commands {
    @ObservedObject var model: LibraryViewModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Photo Folder…") {
                model.presentAddFolderPanel()
            }
            .keyboardShortcut("o", modifiers: .command)
        }

        // No `.keyboardShortcut` on these two: a SwiftUI/AppKit `.undoRedo`
        // CommandGroup quirk means a ⌘Z/⌘⇧Z registered *here* claims the key
        // equivalent at the menu's performKeyEquivalent stage and swallows it
        // -- even though the item shows enabled and a mouse click on it works
        // fine -- so the keystroke never reaches anything, including the
        // `UndoRedoKeyEquivalentFix` local monitor in `LumaHarborMainApp.swift`
        // that actually handles the shortcut (found manually 2026-08-18: the
        // first attempt, adding *only* that monitor while leaving these two
        // `.keyboardShortcut` calls in place, still did nothing). Leaving the
        // key equivalent off here is what lets the monitor's raw key-down
        // handler receive the event at all.
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { model.editor.undo() }
                .disabled(!model.editor.canUndo)

            Button("Redo") { model.editor.redo() }
                .disabled(!model.editor.canRedo)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save Adjustments") {
                Task { await model.editor.save() }
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(model.editor.photo == nil)

            Button("Export JPEG…") {
                model.isShowingExportSheet = true
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(model.selectedPhotoID == nil)
        }

        CommandMenu("Photo") {
            Button("Next Photo") { model.selectNextPhoto() }
                .keyboardShortcut("]", modifiers: .command)
            Button("Previous Photo") { model.selectPreviousPhoto() }
                .keyboardShortcut("[", modifiers: .command)

            Divider()

            Button("Show Original") {
                model.editor.isShowingOriginal.toggle()
            }
            .keyboardShortcut("\\", modifiers: [])
            .disabled(!model.editor.canCompareWithOriginal)

            Button("Reset All Adjustments") { model.editor.resetAll() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.editor.photo == nil || !model.editor.hasEdits)

            Divider()

            Button("Rescan Folder") { model.startScan() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!(model.selectedLibrary?.isOnline ?? false))
        }
    }
}
