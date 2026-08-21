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
@MainActor
enum UndoRedoKeyEquivalentFix {
    /// Which action a key-down event maps to, if any. Kept separate from
    /// `install`'s `NSEvent` handling so the matching rules themselves are
    /// unit-testable without a real window or key event delivery -- neither
    /// of which XCTest can drive in this environment.
    enum Action: Equatable {
        case undo
        case redo
    }

    private static var monitor: Any?

    /// `modifierFlags` is masked to `.deviceIndependentFlagsMask` before
    /// comparison so a stray device-dependent bit in the raw event (the low
    /// 16 bits, unrelated to any named modifier) can't spuriously break the
    /// match, while still requiring an *exact* semantic modifier set -- ⌥⌘Z
    /// or ⌃⌘Z must not trigger undo, only plain ⌘Z (redo additionally
    /// requires ⇧).
    static func match(charactersIgnoringModifiers: String?, modifierFlags: NSEvent.ModifierFlags) -> Action? {
        guard charactersIgnoringModifiers?.lowercased() == "z" else { return nil }
        switch modifierFlags.intersection(.deviceIndependentFlagsMask) {
        case [.command]: return .undo
        case [.command, .shift]: return .redo
        default: return nil
        }
    }

    static func install(model: LibraryViewModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { @MainActor event in
            switch match(charactersIgnoringModifiers: event.charactersIgnoringModifiers, modifierFlags: event.modifierFlags) {
            case .undo:
                guard model.editor.canUndo else { return event }
                model.editor.undo()
                return nil
            case .redo:
                guard model.editor.canRedo else { return event }
                model.editor.redo()
                return nil
            case nil:
                return event
            }
        }
    }
}
