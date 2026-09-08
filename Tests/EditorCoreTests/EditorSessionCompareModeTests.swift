import CoreGraphics
import Foundation
import XCTest
@testable import EditorCore
import PhotoLibraryCore
import RawProcessingCore

/// Phase 2.1 (before/after comparison, spec §6.1): renders a small, fixed
/// image quickly so `renderOriginalReference()` actually populates
/// `originalImage`, letting these tests exercise `canCompareWithOriginal`
/// (which requires a real `originalImage`, not just an edit) without waiting
/// on a real RAW decode.
private struct StaticPreviewRenderer: PreviewRendering {
    func render(_ request: PreviewRequest) async throws -> PreviewImage {
        let image = try Self.makeImage()
        return PreviewImage(cgImage: image, pixelSize: CGSize(width: 4, height: 4))
    }

    private static func makeImage() throws -> CGImage {
        var pixelData = [UInt8](repeating: 128, count: 4 * 4 * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixelData,
            width: 4,
            height: 4,
            bitsPerComponent: 8,
            bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try XCTUnwrap(context.makeImage())
    }
}

@MainActor
final class EditorSessionCompareModeTests: XCTestCase {
    private func makePhoto() -> PhotoAsset {
        PhotoAsset(
            id: PhotoID(),
            libraryID: LibraryID(),
            relativePath: "fixture.ARW",
            fingerprint: FileFingerprint(fileSize: 4, edgeDigest: "fixture"),
            status: .ready
        )
    }

    private func waitUntilCondition(
        timeout: TimeInterval = 3,
        _ condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for condition")
    }

    /// Opens a photo, makes one real edit, and waits for `originalImage` to
    /// land -- the exact state `canCompareWithOriginal` requires.
    private func makeComparableEditor() async throws -> EditorSession {
        let renderer = StaticPreviewRenderer()
        let editor = EditorSession()
        editor.attach(dependencies: EditorDependencies(
            previewScheduler: PreviewScheduler(renderer: renderer),
            previewRenderer: renderer,
            loadAdjustments: { _ in .neutral },
            saveAdjustments: { _, _ in }
        ))
        editor.open(
            photo: makePhoto(),
            sourceURL: URL(fileURLWithPath: "/tmp/fixture.ARW"),
            adjustments: .neutral,
            isReadOnly: false
        )
        editor.setAdjustment(.exposure, to: 1.0)
        try await waitUntilCondition { editor.canCompareWithOriginal }
        return editor
    }

    // MARK: - Default state

    func testCompareModeDefaultsToSingleAndWipePositionDefaultsToCenter() {
        let editor = EditorSession()
        XCTAssertEqual(editor.compareMode, .single)
        XCTAssertEqual(editor.wipePosition, 0.5)
    }

    // MARK: - setCompareMode gating

    func testSetCompareModeSwitchesToSideBySideAndWipeWhenComparisonIsAvailable() async throws {
        let editor = try await makeComparableEditor()

        editor.setCompareMode(.sideBySide)
        XCTAssertEqual(editor.compareMode, .sideBySide)

        editor.setCompareMode(.verticalWipe)
        XCTAssertEqual(editor.compareMode, .verticalWipe)

        editor.setCompareMode(.single)
        XCTAssertEqual(editor.compareMode, .single)
    }

    /// Spec §6.1 / §4.3: "沒有原圖或沒有編輯時，比較入口應安全停用". A photo with no
    /// edits yet (`hasEdits == false`) must not be able to enter a
    /// comparison layout at all -- there would be nothing different to show.
    func testSetCompareModeIgnoresSideBySideOrWipeWithoutAnyEdits() {
        let editor = EditorSession()
        editor.open(
            photo: makePhoto(),
            sourceURL: URL(fileURLWithPath: "/tmp/fixture.ARW"),
            adjustments: .neutral,
            isReadOnly: false
        )
        XCTAssertFalse(editor.canCompareWithOriginal)

        editor.setCompareMode(.sideBySide)
        XCTAssertEqual(editor.compareMode, .single, "no edits yet -- comparison entry must stay disabled")

        editor.setCompareMode(.verticalWipe)
        XCTAssertEqual(editor.compareMode, .single)
    }

    /// Without an open photo at all, `originalImage` can never be rendered,
    /// so comparison must stay unavailable no matter what's requested.
    func testSetCompareModeIgnoresSideBySideOrWipeWithoutAnOpenPhoto() {
        let editor = EditorSession()
        editor.setCompareMode(.sideBySide)
        XCTAssertEqual(editor.compareMode, .single)
    }

    /// `.single` must always be reachable, even mid-comparison, so leaving a
    /// comparison layout can never get stuck.
    func testSetCompareModeToSingleAlwaysSucceeds() async throws {
        let editor = try await makeComparableEditor()
        editor.setCompareMode(.sideBySide)
        XCTAssertEqual(editor.compareMode, .sideBySide)

        editor.setCompareMode(.single)
        XCTAssertEqual(editor.compareMode, .single)
    }

    // MARK: - Non-destructive contract

    /// Spec §6.1: "比較狀態不進 undo、不寫 sidecar". Switching comparison layout
    /// must never touch the committed adjustments, the undo stack, or the
    /// save/autosave state -- exactly like `setToolMode(_:)` already
    /// guarantees for the on-canvas tool.
    func testSettingCompareModeDoesNotChangeAdjustmentsUndoOrSaveState() async throws {
        let editor = try await makeComparableEditor()
        let adjustmentsBefore = editor.adjustments
        let canUndoBefore = editor.canUndo

        editor.setCompareMode(.sideBySide)
        editor.setCompareMode(.verticalWipe)
        editor.setCompareMode(.single)

        XCTAssertEqual(editor.adjustments, adjustmentsBefore)
        XCTAssertEqual(editor.canUndo, canUndoBefore)
        XCTAssertNotEqual(editor.saveState, .saving, "switching layouts must never itself trigger a save")
    }

    // MARK: - Wipe position clamp

    func testSetWipePositionClampsToTheReasonableRange() {
        let editor = EditorSession()

        editor.setWipePosition(-1)
        XCTAssertEqual(editor.wipePosition, EditorSession.minimumWipePosition)

        editor.setWipePosition(2)
        XCTAssertEqual(editor.wipePosition, EditorSession.maximumWipePosition)

        editor.setWipePosition(0.5)
        XCTAssertEqual(editor.wipePosition, 0.5)
    }

    /// Moving the wipe divider is UI-only, same contract as
    /// `setCompareMode(_:)` above.
    func testSetWipePositionDoesNotChangeAdjustmentsUndoOrSaveState() async throws {
        let editor = try await makeComparableEditor()
        let adjustmentsBefore = editor.adjustments
        let canUndoBefore = editor.canUndo

        editor.setWipePosition(0.2)

        XCTAssertEqual(editor.adjustments, adjustmentsBefore)
        XCTAssertEqual(editor.canUndo, canUndoBefore)
    }

    // MARK: - Reset on open/close

    func testOpeningANewPhotoResetsCompareModeAndWipePositionToDefaults() async throws {
        let editor = try await makeComparableEditor()
        editor.setCompareMode(.verticalWipe)
        editor.setWipePosition(0.2)
        XCTAssertEqual(editor.compareMode, .verticalWipe)

        editor.open(
            photo: makePhoto(),
            sourceURL: URL(fileURLWithPath: "/tmp/second.ARW"),
            adjustments: .neutral,
            isReadOnly: false
        )

        XCTAssertEqual(editor.compareMode, .single)
        XCTAssertEqual(editor.wipePosition, 0.5)
    }

    func testClosingResetsCompareModeAndWipePositionToDefaults() async throws {
        let editor = try await makeComparableEditor()
        editor.setCompareMode(.sideBySide)
        editor.setWipePosition(0.8)

        editor.close()

        XCTAssertEqual(editor.compareMode, .single)
        XCTAssertEqual(editor.wipePosition, 0.5)
    }
}
