import Foundation
import XCTest
@testable import EditorCore
import PhotoLibraryCore
import RawProcessingCore

/// Codex review (Task 6, round 2 follow-up): `SafeErrorPresentationTests`
/// proves the *mapper* is safe in isolation, but that alone doesn't prove
/// `EditorSession` actually routes its real render- and save-failure paths
/// through it. These tests drive `EditorSession` itself -- a real render
/// failure via `PreviewScheduler`, a real save failure via `saveAdjustments`
/// -- and assert directly on `editor.alert`/`editor.saveState`.
private struct FailingPreviewRenderer: PreviewRendering {
    let error: Error
    func render(_ request: PreviewRequest) async throws -> PreviewImage {
        throw error
    }
}

private struct NeverPreviewRenderer: PreviewRendering {
    func render(_ request: PreviewRequest) async throws -> PreviewImage {
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }
}

private struct WriteFailure: LocalizedError {
    var errorDescription: String? {
        "Couldn't write to /Users/alice/Pictures/Import/DSC_secret.ARW"
    }
}

@MainActor
final class EditorSessionAlertPrivacyTests: XCTestCase {
    private let sensitivePath = "/Users/alice/Pictures/Import/DSC_secret.ARW"

    private func makePhoto() -> PhotoAsset {
        PhotoAsset(
            id: PhotoID(),
            libraryID: LibraryID(),
            relativePath: "fixture.ARW",
            fingerprint: FileFingerprint(fileSize: 4, edgeDigest: "fixture"),
            status: .ready
        )
    }

    private func assertNoLeak(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(text.contains("/Users/"), "leaked /Users/ in \"\(text)\"", file: file, line: line)
        XCTAssertFalse(text.contains(sensitivePath), "leaked the fixture path in \"\(text)\"", file: file, line: line)
        XCTAssertFalse(text.contains("secret"), "leaked the filename in \"\(text)\"", file: file, line: line)
    }

    /// A real render failure, driven through `EditorSession.open` and its
    /// `PreviewScheduler`/`PreviewRendering` seam exactly as production
    /// does, must not leak the source path into `editor.alert`.
    func testARealRenderFailureNeverLeaksThePathIntoEditorSessionsAlert() async throws {
        let renderer = FailingPreviewRenderer(error: RawDecodingError.fileUnavailable(path: sensitivePath))
        let editor = EditorSession()
        editor.attach(dependencies: EditorDependencies(
            previewScheduler: PreviewScheduler(renderer: renderer),
            previewRenderer: renderer,
            loadAdjustments: { _ in .neutral },
            saveAdjustments: { _, _ in }
        ))
        editor.open(
            photo: makePhoto(),
            sourceURL: URL(fileURLWithPath: sensitivePath),
            adjustments: .neutral,
            isReadOnly: false
        )

        let deadline = Date().addingTimeInterval(3)
        while editor.alert == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let alert = try XCTUnwrap(editor.alert, "expected the render failure to surface an alert")
        assertNoLeak(alert.title)
        assertNoLeak(alert.message)
        assertNoLeak(alert.nextStep ?? "")
    }

    /// A real save failure, driven through `flushPendingEdits()` exactly as
    /// production does, must not leak a path into `editor.alert` or
    /// `editor.saveState`'s `.failed` message.
    func testARealSaveFailureNeverLeaksThePathIntoEditorSessionsAlertOrSaveState() async throws {
        let renderer = NeverPreviewRenderer()
        let editor = EditorSession()
        editor.attach(dependencies: EditorDependencies(
            previewScheduler: PreviewScheduler(renderer: renderer),
            previewRenderer: renderer,
            loadAdjustments: { _ in .neutral },
            saveAdjustments: { _, _ in throw WriteFailure() }
        ))
        editor.open(
            photo: makePhoto(),
            sourceURL: URL(fileURLWithPath: "/tmp/fixture.ARW"),
            adjustments: .neutral,
            isReadOnly: false
        )
        editor.setAdjustment(.exposure, to: 1.2)

        let flushed = await editor.flushPendingEdits()
        XCTAssertFalse(flushed)

        let alert = try XCTUnwrap(editor.alert)
        assertNoLeak(alert.title)
        assertNoLeak(alert.message)
        assertNoLeak(alert.nextStep ?? "")

        guard case .failed(let message) = editor.saveState else {
            XCTFail("expected saveState to be .failed, was \(editor.saveState)")
            return
        }
        assertNoLeak(message)
    }
}
