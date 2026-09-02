import Foundation
import XCTest
@testable import EditorCore
import PhotoLibraryCore
import RawProcessingCore

@MainActor
final class EditorSessionEditingTests: XCTestCase {
    func testOneAdjustmentCreatesOneUndoEntry() {
        let editor = EditorSession()
        let photo = PhotoAsset(
            id: PhotoID(),
            libraryID: LibraryID(),
            relativePath: "fixture.ARW",
            fingerprint: FileFingerprint(fileSize: 4, edgeDigest: "fixture"),
            status: .ready
        )
        editor.open(
            photo: photo,
            sourceURL: URL(fileURLWithPath: "/fixture.ARW"),
            adjustments: .neutral,
            isReadOnly: false
        )

        editor.setAdjustment(.exposure, to: 1.25)
        XCTAssertEqual(editor.adjustments.exposure, 1.25)
        XCTAssertTrue(editor.canUndo)

        editor.undo()
        XCTAssertEqual(editor.adjustments.exposure, 0)
        XCTAssertFalse(editor.canUndo)
    }

    /// AwayPhotoRawEditor parity Phase 1 Task 3: the grouped inspector
    /// panels (Color/Curve/Detail/Effects) edit sub-struct fields that have
    /// no `AdjustmentKind` case of their own -- `setAdjustment(_:to:)` can't
    /// reach `hsl`, `advancedToneCurve`, `sharpening`, `noiseReduction`,
    /// `vignette` or `grain`. `updateAdjustments(_:)` is the one general
    /// entry point those panels go through instead, and it must land on the
    /// same undo stack `setAdjustment` does.
    private func makeOpenEditor() -> EditorSession {
        let editor = EditorSession()
        let photo = PhotoAsset(
            id: PhotoID(),
            libraryID: LibraryID(),
            relativePath: "fixture.ARW",
            fingerprint: FileFingerprint(fileSize: 4, edgeDigest: "fixture"),
            status: .ready
        )
        editor.open(
            photo: photo,
            sourceURL: URL(fileURLWithPath: "/fixture.ARW"),
            adjustments: .neutral,
            isReadOnly: false
        )
        return editor
    }

    func testUpdateAdjustmentsAppliesTheTransformAndCreatesOneUndoEntry() {
        let editor = makeOpenEditor()

        editor.updateAdjustments { $0.hsl.red.saturation = 40 }

        XCTAssertEqual(editor.adjustments.hsl.red.saturation, 40)
        XCTAssertTrue(editor.canUndo)

        editor.undo()
        XCTAssertEqual(editor.adjustments.hsl.red.saturation, 0)
        XCTAssertFalse(editor.canUndo)
    }

    func testUpdateAdjustmentsIsANoOpWhenTheTransformDoesNotChangeAnything() {
        let editor = makeOpenEditor()

        editor.updateAdjustments { $0.hsl.red.saturation = 0 }

        XCTAssertFalse(editor.canUndo, "setting a field to its already-current value must not push an undo entry")
    }

    func testUpdateAdjustmentsDoesNothingWithoutAnOpenPhoto() {
        let editor = EditorSession()

        editor.updateAdjustments { $0.hsl.red.saturation = 40 }

        XCTAssertEqual(editor.adjustments, .neutral)
        XCTAssertFalse(editor.canUndo)
    }

    func testUpdateAdjustmentsCanEditEverySubStructTheGroupedPanelsNeed() {
        let editor = makeOpenEditor()

        editor.updateAdjustments { $0.sharpening.amount = 30 }
        editor.updateAdjustments { $0.noiseReduction.luminanceAmount = 20 }
        editor.updateAdjustments { $0.vignette.amount = -15 }
        editor.updateAdjustments { $0.grain.amount = 10 }
        editor.updateAdjustments { $0.advancedToneCurve = AdvancedToneCurve(points: [ToneCurvePoint(x: 0.25, y: 0.5)]) }

        XCTAssertEqual(editor.adjustments.sharpening.amount, 30)
        XCTAssertEqual(editor.adjustments.noiseReduction.luminanceAmount, 20)
        XCTAssertEqual(editor.adjustments.vignette.amount, -15)
        XCTAssertEqual(editor.adjustments.grain.amount, 10)
        XCTAssertFalse(editor.adjustments.advancedToneCurve.isIdentity)
    }
}
