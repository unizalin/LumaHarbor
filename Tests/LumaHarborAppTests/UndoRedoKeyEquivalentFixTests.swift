import AppKit
import XCTest
@testable import LumaHarborApp

/// `UndoRedoKeyEquivalentFix.match` is the matching logic behind the local
/// key-down monitor added in `20460ca` to route ⌘Z/⌘⇧Z around a SwiftUI
/// `CommandGroup(replacing: .undoRedo)` gap (see the doc comment on
/// `UndoRedoKeyEquivalentFix` in `LumaHarborMainApp.swift`). The monitor
/// itself needs a real `NSEvent` delivered to a real window, which XCTest
/// can't drive here, but the matching rules are pure and worth pinning down
/// on their own -- this is also where a real bug lived until now: the
/// original implementation only checked `modifierFlags.contains(.command)`,
/// so ⌥⌘Z or ⌃⌘Z were incorrectly treated as plain undo.
@MainActor
final class UndoRedoKeyEquivalentFixTests: XCTestCase {
    func testPlainCommandZIsUndo() {
        XCTAssertEqual(
            UndoRedoKeyEquivalentFix.match(charactersIgnoringModifiers: "z", modifierFlags: [.command]),
            .undo
        )
    }

    func testCommandShiftZIsRedo() {
        XCTAssertEqual(
            UndoRedoKeyEquivalentFix.match(charactersIgnoringModifiers: "z", modifierFlags: [.command, .shift]),
            .redo
        )
    }

    func testUppercaseCharacterFromShiftStillMatches() {
        // charactersIgnoringModifiers respects Shift, so ⇧⌘Z reports "Z", not "z".
        XCTAssertEqual(
            UndoRedoKeyEquivalentFix.match(charactersIgnoringModifiers: "Z", modifierFlags: [.command, .shift]),
            .redo
        )
    }

    func testZWithoutCommandDoesNotMatch() {
        XCTAssertNil(UndoRedoKeyEquivalentFix.match(charactersIgnoringModifiers: "z", modifierFlags: []))
        XCTAssertNil(UndoRedoKeyEquivalentFix.match(charactersIgnoringModifiers: "z", modifierFlags: [.shift]))
    }

    func testCommandWithoutZDoesNotMatch() {
        XCTAssertNil(UndoRedoKeyEquivalentFix.match(charactersIgnoringModifiers: "x", modifierFlags: [.command]))
        XCTAssertNil(UndoRedoKeyEquivalentFix.match(charactersIgnoringModifiers: nil, modifierFlags: [.command]))
    }

    /// Regression: an extra held modifier must not be silently ignored.
    /// ⌥⌘Z and ⌃⌘Z are different shortcuts (or no shortcut at all) in every
    /// standard macOS app, not an alias for plain undo.
    func testExtraModifierPreventsMatch() {
        XCTAssertNil(UndoRedoKeyEquivalentFix.match(charactersIgnoringModifiers: "z", modifierFlags: [.command, .option]))
        XCTAssertNil(UndoRedoKeyEquivalentFix.match(charactersIgnoringModifiers: "z", modifierFlags: [.command, .control]))
        XCTAssertNil(UndoRedoKeyEquivalentFix.match(charactersIgnoringModifiers: "z", modifierFlags: [.command, .shift, .option]))
    }

    /// Regression: `NSEvent.modifierFlags`'s raw value can carry
    /// device-dependent bits (the low 16 bits, e.g. describing which
    /// physical key produced the event) alongside the semantic flags in the
    /// high 16 bits (`.deviceIndependentFlagsMask`). Real events can have
    /// stray low bits set; those must not break an otherwise exact match,
    /// since `match` explicitly masks to `.deviceIndependentFlagsMask`
    /// before comparing.
    func testIncidentalDeviceDependentBitIsIgnored() {
        let withStrayLowBit = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x0002)
        XCTAssertEqual(
            UndoRedoKeyEquivalentFix.match(charactersIgnoringModifiers: "z", modifierFlags: withStrayLowBit),
            .undo
        )
    }
}
