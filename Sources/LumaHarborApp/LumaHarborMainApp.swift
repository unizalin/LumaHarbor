import AppKit
import SwiftUI

/// The SwiftUI app entry point.
///
/// Named `LumaHarborMainApp` rather than `LumaHarborApp` because the module is
/// already called `LumaHarborApp`; a type of the same name would shadow it.
public struct LumaHarborMainApp: App {
    @StateObject private var libraryModel = LibraryViewModel()
    @NSApplicationDelegateAdaptor(LumaHarborAppDelegate.self) private var appDelegate

    public init() {}

    public var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(libraryModel)
                .frame(minWidth: 1_100, minHeight: 700)
                .onAppear { appDelegate.model = libraryModel }
        }
        .commands {
            LumaHarborCommands(model: libraryModel)
        }

        Settings {
            SettingsView()
        }
    }
}

/// Two earlier fixes for ⌘Z/⌘⇧Z doing nothing both failed real-hardware
/// testing (2026-08-18, then again 2026-09-05 with a hardware-level `CGEvent`
/// control-tested against TextEdit): a `CommandGroup(replacing: .undoRedo)`
/// with `.keyboardShortcut` set directly, and later the same CommandGroup
/// backed by an `NSEvent.addLocalMonitorForEvents` local key-down monitor.
/// Neither puts a real `NSResponder` implementing `undo:`/`redo:` anywhere
/// AppKit's standard key-equivalent dispatch can find it, which is what every
/// other Mac app (including TextEdit, confirmed by the same control test)
/// relies on for ⌘Z to work at all.
///
/// This fix instead leaves `.undoRedo` *unreplaced* -- so SwiftUI keeps
/// generating the system's own Undo/Redo menu items, with their OS-standard
/// ⌘Z/⌘⇧Z key equivalents and target `nil` (first-responder-chain dispatch)
/// -- and gives the app delegate real `undo(_:)`/`redo(_:)` methods so that
/// chain has somewhere to land regardless of which view currently has focus.
/// `NSApplication`'s delegate is the last stop in `NSApp.target(for:)`'s
/// search order, after the key window and its responder chain, so a focused
/// text field's own undo (e.g. mid-rename) still wins over this app-level
/// fallback, matching standard multi-level Mac undo behavior.
@MainActor
final class LumaHarborAppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    weak var model: LibraryViewModel?

    @objc func undo(_ sender: Any?) {
        model?.editor.undo()
    }

    @objc func redo(_ sender: Any?) {
        model?.editor.redo()
    }

    /// AppKit calls this on whichever responder it found for the menu item's
    /// action -- here, only ever `undo(_:)`/`redo(_:)`, since those are the
    /// only actions this delegate implements. Anything else is left enabled,
    /// matching `NSMenuItemValidation`'s "no opinion" default.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)): return model?.editor.canUndo ?? false
        case #selector(redo(_:)): return model?.editor.canRedo ?? false
        default: return true
        }
    }
}
