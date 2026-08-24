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
}
