import SwiftUI
import Localization

/// macOS menu bar and keyboard shortcuts (spec §4: AppKit-backed capabilities
/// where SwiftUI alone isn't enough).
struct LumaHarborCommands: Commands {
    @ObservedObject var model: LibraryViewModel

    /// Phase 2.3 (spec §6.3): the same `@AppStorage` keys `RootView`/
    /// `EditorView` bind, so toggling from the menu bar and toggling from
    /// `RootView`'s own Workspace menu always agree.
    @AppStorage(WorkspaceLayoutState.StorageKey.showSidebar) private var showSidebar = true
    @AppStorage(WorkspaceLayoutState.StorageKey.showInspector) private var showInspector = true
    @AppStorage(WorkspaceLayoutState.StorageKey.showFilmstrip) private var showFilmstrip = true
    @AppStorage(WorkspaceLayoutState.StorageKey.focusMode) private var focusMode = false

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

            Button(L10n.t("Export Selected Photos…")) {
                model.isShowingBatchExportSheet = true
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(model.selectedPhotoIDs.isEmpty)
        }

        // Phase 2.3 (spec §6.3): a menu-bar path to the same workspace
        // toggles `RootView`'s own Workspace menu offers, plus the one
        // shortcut the spec calls for -- Focus Mode. Command+Shift always
        // gates it, so a plain "f" keeps typing normally in any text field.
        CommandMenu(L10n.t("View")) {
            Toggle(L10n.t("Show Sidebar"), isOn: $showSidebar)
            Toggle(L10n.t("Show Inspector"), isOn: $showInspector)
            Toggle(L10n.t("Show Filmstrip"), isOn: $showFilmstrip)
            Divider()
            Toggle(L10n.t("Distraction-Free Mode"), isOn: $focusMode)
                .keyboardShortcut("f", modifiers: [.command, .shift])
        }

        CommandMenu(L10n.t("Photo")) {
            Button(L10n.t("Next Photo")) { model.selectNextPhoto() }
                .keyboardShortcut("]", modifiers: .command)
            Button(L10n.t("Previous Photo")) { model.selectPreviousPhoto() }
                .keyboardShortcut("[", modifiers: .command)

            Button(L10n.t("Select All")) { model.selectAllVisible() }
                .keyboardShortcut("a", modifiers: .command)
                .disabled(model.visiblePhotos.isEmpty)

            Divider()

            Button(L10n.t("Show Original")) {
                model.editor.isShowingOriginal.toggle()
            }
            .keyboardShortcut("\\", modifiers: [])
            .disabled(!model.editor.canCompareWithOriginal)

            Button(L10n.t("Reset All Adjustments")) { model.editor.resetAll() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.editor.photo == nil || !model.editor.hasEdits)

            Divider()

            Menu(L10n.t("Rating")) {
                ForEach(0...5, id: \.self) { value in
                    Button {
                        guard Self.allowsPhotoShortcut else { return }
                        model.setRatingForSelectedPhoto(value)
                    } label: {
                        Label(value == 0 ? L10n.t("Unrated") : "\(value)", systemImage: "star.fill")
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(value))), modifiers: [])
                }
            }

            Menu(L10n.t("Flag")) {
                Button(L10n.t("Pick")) {
                    guard Self.allowsPhotoShortcut else { return }
                    model.setFlagForSelectedPhoto(.pick)
                }
                .keyboardShortcut("p", modifiers: [])
                Button(L10n.t("Reject")) {
                    guard Self.allowsPhotoShortcut else { return }
                    model.setFlagForSelectedPhoto(.reject)
                }
                .keyboardShortcut("x", modifiers: [])
                Button(L10n.t("Clear Flag")) {
                    guard Self.allowsPhotoShortcut else { return }
                    model.setFlagForSelectedPhoto(.none)
                }
                .keyboardShortcut("u", modifiers: [])
            }

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

    private static var allowsPhotoShortcut: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return true }
        if responder is NSTextField || responder is NSTextView { return false }
        if let fieldEditor = responder as? NSView, fieldEditor.nextResponder is NSTextView {
            return false
        }
        return true
    }
}
