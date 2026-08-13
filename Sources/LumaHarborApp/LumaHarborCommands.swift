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

        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { model.editor.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!model.editor.canUndo)

            Button("Redo") { model.editor.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
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
