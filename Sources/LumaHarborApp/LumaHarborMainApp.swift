import AppKit
import Combine
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
/// SwiftUI's standard Undo/Redo items keep the OS key equivalents, but its
/// hosting responder can claim `undo:` while reporting an empty UndoManager;
/// that disables the menu before dispatch ever reaches the app delegate.
/// Routing only those two items explicitly to this delegate avoids that dead
/// end. Focused editable text still gets first priority through its own
/// UndoManager, then the photo editor is the app-level fallback.
@MainActor
final class LumaHarborAppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var modelObservation: AnyCancellable?
    private var menuDelegateProxies: [ObjectIdentifier: UndoRedoMenuDelegateProxy] = [:]
    var mainMenuProvider: () -> NSMenu? = { NSApplication.shared.mainMenu }

    weak var model: LibraryViewModel? {
        didSet {
            modelObservation = model?.objectWillChange.sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.installUndoRedoMenuRouting(in: self?.mainMenuProvider())
                }
            }
            installUndoRedoMenuRouting(in: mainMenuProvider())
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.installUndoRedoMenuRouting(in: self?.mainMenuProvider())
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        installUndoRedoMenuRouting(in: mainMenuProvider())
    }

    @objc func undo(_ sender: Any?) {
        if let textView = focusedEditableTextView {
            textView.undoManager?.undo()
        } else {
            model?.editor.undo()
        }
    }

    @objc func redo(_ sender: Any?) {
        if let textView = focusedEditableTextView {
            textView.undoManager?.redo()
        } else {
            model?.editor.redo()
        }
    }

    /// AppKit calls this on whichever responder it found for the menu item's
    /// action -- here, only ever `undo(_:)`/`redo(_:)`, since those are the
    /// only actions this delegate implements. Anything else is left enabled,
    /// matching `NSMenuItemValidation`'s "no opinion" default.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)):
            return focusedEditableTextView?.undoManager?.canUndo
                ?? model?.editor.canUndo
                ?? false
        case #selector(redo(_:)):
            return focusedEditableTextView?.undoManager?.canRedo
                ?? model?.editor.canRedo
                ?? false
        default: return true
        }
    }

    func routeUndoRedoMenuItems(in menu: NSMenu?) {
        for item in menu?.items ?? [] {
            switch item.action {
            case #selector(undo(_:)), #selector(redo(_:)):
                if item.target !== self {
                    item.target = self
                }
            default:
                break
            }
            routeUndoRedoMenuItems(in: item.submenu)
        }
    }

    func installUndoRedoMenuRouting(in menu: NSMenu?) {
        guard let menu else { return }
        routeUndoRedoMenuItems(in: menu)

        for item in menu.items {
            guard let submenu = item.submenu else { continue }
            let containsUndoRedo = submenu.items.contains {
                $0.action == #selector(undo(_:)) || $0.action == #selector(redo(_:))
            }
            if containsUndoRedo {
                let identifier = ObjectIdentifier(submenu)
                if let proxy = submenu.delegate as? UndoRedoMenuDelegateProxy {
                    menuDelegateProxies[identifier] = proxy
                } else {
                    let proxy = UndoRedoMenuDelegateProxy(
                        downstream: submenu.delegate,
                        owner: self
                    )
                    menuDelegateProxies[identifier] = proxy
                    submenu.delegate = proxy
                }
            }
            installUndoRedoMenuRouting(in: submenu)
        }
    }

    private var focusedEditableTextView: NSTextView? {
        guard let textView = NSApplication.shared.keyWindow?.firstResponder as? NSTextView,
              textView.isEditable else { return nil }
        return textView
    }
}

/// Keeps SwiftUI's private menu delegate in charge of rebuilding the menu,
/// then patches Undo/Redo only after that rebuild finishes. Optional delegate
/// callbacks not implemented here continue to the original delegate through
/// Objective-C forwarding.
@MainActor
private final class UndoRedoMenuDelegateProxy: NSObject, NSMenuDelegate {
    private weak var downstream: (any NSMenuDelegate)?
    private weak var owner: LumaHarborAppDelegate?

    init(downstream: (any NSMenuDelegate)?, owner: LumaHarborAppDelegate) {
        self.downstream = downstream
        self.owner = owner
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        downstream?.menuNeedsUpdate?(menu)
        owner?.routeUndoRedoMenuItems(in: menu)
    }

    override func responds(to selector: Selector!) -> Bool {
        selector == #selector(NSMenuDelegate.menuNeedsUpdate(_:))
            || downstream?.responds(to: selector) == true
            || super.responds(to: selector)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if downstream?.responds(to: selector) == true {
            return downstream
        }
        return super.forwardingTarget(for: selector)
    }
}
