import AppKit
import SwiftUI

/// The SwiftUI app entry point.
///
/// Named `LumaHarborMainApp` rather than `LumaHarborApp` because the module is
/// already called `LumaHarborApp`; a type of the same name would shadow it.
public struct LumaHarborMainApp: App {
    @StateObject private var libraryModel = LibraryViewModel()

    public init() {}

    public var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(libraryModel)
                .frame(minWidth: 1_100, minHeight: 700)
                .onAppear { UndoRedoKeyEquivalentFix.install(model: libraryModel) }
        }
        .commands {
            LumaHarborCommands(model: libraryModel)
        }
    }
}

/// `CommandGroup(replacing: .undoRedo)` in `LumaHarborCommands` gives Undo/Redo
/// working, correctly-enabled menu items — clicking them works — but ⌘Z/⌘⇧Z
/// themselves never reach the menu's key-equivalent matching (confirmed by
/// hand 2026-08-18: menu click undoes fine, the keyboard shortcut does
/// nothing, even after clicking away from every slider to rule out a focused
/// control eating the key). This is a known SwiftUI-on-macOS gap: `.undoRedo`
/// key equivalents aren't reliably routed without a real `NSResponder`
/// implementing `undo:`/`redo:`. A local key-down monitor -- which AppKit
/// consults ahead of ordinary key-equivalent dispatch -- is the standard
/// workaround.
private enum UndoRedoKeyEquivalentFix {
    private static var monitor: Any?

    @MainActor
    static func install(model: LibraryViewModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { @MainActor event in
            guard event.charactersIgnoringModifiers?.lowercased() == "z",
                  event.modifierFlags.contains(.command) else { return event }

            if event.modifierFlags.contains(.shift) {
                guard model.editor.canRedo else { return event }
                model.editor.redo()
            } else {
                guard model.editor.canUndo else { return event }
                model.editor.undo()
            }
            return nil
        }
    }
}
