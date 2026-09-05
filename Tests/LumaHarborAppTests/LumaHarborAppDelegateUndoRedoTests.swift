import AppKit
import XCTest
@testable import EditorCore
@testable import LumaHarborApp
import PhotoLibraryCore

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
