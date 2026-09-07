import AppKit
import XCTest
@testable import EditorCore
@testable import LumaHarborApp
import PhotoLibraryCore

@MainActor
private final class RecordingMenuDelegate: NSObject, NSMenuDelegate {
    private(set) var updateCount = 0
    private(set) var willOpenCount = 0

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateCount += 1
        menu.items.first { $0.action == #selector(LumaHarborAppDelegate.undo(_:)) }?.target = nil
    }

    func menuWillOpen(_ menu: NSMenu) {
        willOpenCount += 1
    }
}

/// `LumaHarborAppDelegate` is the fix for ⌘Z/⌘⇧Z doing nothing (see its doc
/// comment in `LumaHarborMainApp.swift`): it gives the app delegate real
/// `undo(_:)`/`redo(_:)` methods so the *unreplaced* system `.undoRedo`
/// CommandGroup -- with its OS-standard key equivalents and `nil`-target,
/// first-responder-chain dispatch -- has somewhere to land. `NSEvent`
/// delivery to a real window still isn't drivable from XCTest here, so this
/// pins down the one part of the fix that is directly testable: that the
/// delegate's `undo(_:)`/`redo(_:)`/`validateMenuItem(_:)` actually delegate
/// to the model's editor, and specifically to guard against regressing back
/// to a custom `CommandGroup(replacing: .undoRedo)` (which loses this
/// delegate's `nil`-target dispatch target entirely) without anyone
/// noticing.
@MainActor
final class LumaHarborAppDelegateUndoRedoTests: XCTestCase {
    private func makeOpenModel() -> LibraryViewModel {
        let model = LibraryViewModel()
        let photo = PhotoAsset(
            id: PhotoID(),
            libraryID: LibraryID(),
            relativePath: "fixture.ARW",
            fingerprint: FileFingerprint(fileSize: 4, edgeDigest: "fixture"),
            status: .ready
        )
        model.editor.open(
            photo: photo,
            sourceURL: URL(fileURLWithPath: "/fixture.ARW"),
            adjustments: .neutral,
            isReadOnly: false
        )
        return model
    }

    private func menuItem(action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
        item.isEnabled = true
        return item
    }

    func testUndoActionDelegatesToTheModelsEditor() {
        let delegate = LumaHarborAppDelegate()
        let model = makeOpenModel()
        delegate.model = model
        model.editor.setAdjustment(.exposure, to: 1.25)
        XCTAssertTrue(model.editor.canUndo)

        delegate.undo(nil)

        XCTAssertEqual(model.editor.adjustments.exposure, 0)
        XCTAssertFalse(model.editor.canUndo)
    }

    func testRedoActionDelegatesToTheModelsEditor() {
        let delegate = LumaHarborAppDelegate()
        let model = makeOpenModel()
        delegate.model = model
        model.editor.setAdjustment(.exposure, to: 1.25)
        model.editor.undo()
        XCTAssertTrue(model.editor.canRedo)

        delegate.redo(nil)

        XCTAssertEqual(model.editor.adjustments.exposure, 1.25)
        XCTAssertFalse(model.editor.canRedo)
    }

    func testValidateMenuItemReflectsCanUndoAndCanRedo() {
        let delegate = LumaHarborAppDelegate()
        let model = makeOpenModel()
        delegate.model = model
        let undoItem = menuItem(action: #selector(LumaHarborAppDelegate.undo(_:)))
        let redoItem = menuItem(action: #selector(LumaHarborAppDelegate.redo(_:)))

        XCTAssertFalse(delegate.validateMenuItem(undoItem), "nothing to undo yet")
        XCTAssertFalse(delegate.validateMenuItem(redoItem), "nothing to redo yet")

        model.editor.setAdjustment(.exposure, to: 1.25)
        XCTAssertTrue(delegate.validateMenuItem(undoItem))
        XCTAssertFalse(delegate.validateMenuItem(redoItem))

        model.editor.undo()
        XCTAssertFalse(delegate.validateMenuItem(undoItem))
        XCTAssertTrue(delegate.validateMenuItem(redoItem))
    }

    func testRoutingUndoRedoMenuItemsTargetsTheDelegateWithoutChangingOtherEditActions() {
        let delegate = LumaHarborAppDelegate()
        let mainMenu = NSMenu()
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        let undoItem = NSMenuItem(
            title: "Undo",
            action: #selector(LumaHarborAppDelegate.undo(_:)),
            keyEquivalent: "z"
        )
        let redoItem = NSMenuItem(
            title: "Redo",
            action: #selector(LumaHarborAppDelegate.redo(_:)),
            keyEquivalent: "Z"
        )
        let copyItem = NSMenuItem(
            title: "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        )
        editMenu.addItem(undoItem)
        editMenu.addItem(redoItem)
        editMenu.addItem(copyItem)
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        delegate.routeUndoRedoMenuItems(in: mainMenu)

        XCTAssertTrue(undoItem.target === delegate)
        XCTAssertTrue(redoItem.target === delegate)
        XCTAssertNil(copyItem.target)
        XCTAssertEqual(undoItem.keyEquivalent, "z")
        XCTAssertEqual(redoItem.keyEquivalent, "Z")
    }

    func testModelChangeReroutesUndoAfterSwiftUIRebuildsTheEditMenu() async {
        let delegate = LumaHarborAppDelegate()
        let model = makeOpenModel()
        let mainMenu = NSMenu()
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        let undoItem = NSMenuItem(
            title: "Undo",
            action: #selector(LumaHarborAppDelegate.undo(_:)),
            keyEquivalent: "z"
        )
        editMenu.addItem(undoItem)
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        delegate.mainMenuProvider = { mainMenu }
        delegate.model = model
        XCTAssertTrue(undoItem.target === delegate)

        // SwiftUI regenerates standard menu items after observable state
        // changes, which clears the explicit AppKit target installed above.
        undoItem.target = nil
        model.editor.setAdjustment(.exposure, to: 1.25)
        await Task.yield()
        await Task.yield()

        XCTAssertTrue(undoItem.target === delegate)
    }

    func testMenuDelegateProxyRoutesUndoAfterTheExistingDelegateUpdatesTheMenu() {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        let undoItem = NSMenuItem(
            title: "Undo",
            action: #selector(LumaHarborAppDelegate.undo(_:)),
            keyEquivalent: "z"
        )
        let existingDelegate = RecordingMenuDelegate()
        editMenu.addItem(undoItem)
        editMenu.delegate = existingDelegate
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        let delegate = LumaHarborAppDelegate()

        delegate.installUndoRedoMenuRouting(in: mainMenu)
        editMenu.delegate?.menuNeedsUpdate?(editMenu)
        editMenu.delegate?.menuWillOpen?(editMenu)

        XCTAssertEqual(existingDelegate.updateCount, 1)
        XCTAssertEqual(existingDelegate.willOpenCount, 1)
        XCTAssertTrue(undoItem.target === delegate)
    }

    /// Regression: without a model attached yet (e.g. before the window's
    /// first `onAppear` runs), the delegate must not crash and must leave
    /// Undo/Redo disabled rather than throwing away user edits.
    func testWithoutAModelUndoAndRedoAreDisabledAndDoNothing() {
        let delegate = LumaHarborAppDelegate()
        let undoItem = menuItem(action: #selector(LumaHarborAppDelegate.undo(_:)))
        let redoItem = menuItem(action: #selector(LumaHarborAppDelegate.redo(_:)))

        XCTAssertFalse(delegate.validateMenuItem(undoItem))
        XCTAssertFalse(delegate.validateMenuItem(redoItem))
        delegate.undo(nil)
        delegate.redo(nil)
    }

    /// Regression: an unrelated menu item's action must not be blocked by
    /// this delegate's validation -- `NSMenuItemValidation` is app-wide once
    /// implemented, so a `default: return false` here would silently disable
    /// every other menu item routed through the app delegate.
    func testValidateMenuItemLeavesUnrelatedActionsEnabled() {
        let delegate = LumaHarborAppDelegate()
        delegate.model = makeOpenModel()
        let unrelatedItem = menuItem(action: #selector(NSResponder.selectAll(_:)))

        XCTAssertTrue(delegate.validateMenuItem(unrelatedItem))
    }
}
