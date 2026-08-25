import Foundation
import XCTest
@testable import EditorCore
import PhotoLibraryCore
import RawProcessingCore

/// A `PreviewRendering` that never produces a frame. These tests are about
/// what reaches disk, not what reaches the screen — isolating pixel
/// rendering out entirely is what keeps them fast and independent of
/// `CIRAWFilter`/a real RAW fixture.
private struct NeverPreviewRenderer: PreviewRendering {
    func render(_ request: PreviewRequest) async throws -> PreviewImage {
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }
}

private struct WriteFailure: Error {}

/// Task 6's iPad wiring (`PadEditorModel`) composes a real
/// `PhotoDocumentStore` with a real `EditorSession` exactly as these tests
/// do; that composition lives in a separate `.swiftpm` application package
/// that `swift test` cannot see or run. These tests exercise the same
/// composition and the same contract `PadEditorModel` depends on —
/// document-ID-keyed sidecars, the working copy (not the external source)
/// as the URL the editor decodes and previews from, and save failures never
/// reading as success — through the shared, testable target both platforms
/// actually use.
@MainActor
final class EditorSessionDocumentPersistenceTests: XCTestCase {
    // MARK: - Fixtures

    private func makeFixtureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorDocumentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeEditor(store: PhotoDocumentStore) -> EditorSession {
        let editor = EditorSession()
        let renderer = NeverPreviewRenderer()
        editor.attach(dependencies: EditorDependencies(
            previewScheduler: PreviewScheduler(renderer: renderer),
            previewRenderer: renderer,
            loadAdjustments: { photo in
                try await store.loadAdjustments(documentID: photo.id.rawValue)
            },
            saveAdjustments: { adjustments, photo in
                try await store.saveAdjustments(adjustments, documentID: photo.id.rawValue)
            }
        ))
        return editor
    }

    private func photo(for document: PhotoDocument) -> PhotoAsset {
        PhotoAsset(
            id: PhotoID(document.id),
            libraryID: LibraryID(),
            relativePath: document.workingURL.lastPathComponent,
            fingerprint: document.workingFingerprint,
            status: .ready
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        _ condition: () async throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - Tests

    /// 1 & 2: autosave through a real `EditorSession` + `PhotoDocumentStore`
    /// persists the edit, and the RAW bytes it was opened from are
    /// byte-identical before and after.
    func testAutosavePersistsSidecarWithoutChangingRawBytes() async throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rawURL = root.appendingPathComponent("fixture.ARW")
        try Data(repeating: 0x42, count: 4096).write(to: rawURL)
        let original = try Data(contentsOf: rawURL)

        let store = PhotoDocumentStore(rootURL: root.appendingPathComponent("Store"))
        let document = try await store.openInPlace(rawURL, bookmarkData: nil).document
        let editor = makeEditor(store: store)
        editor.open(
            photo: photo(for: document),
            sourceURL: document.workingURL,
            adjustments: .neutral,
            isReadOnly: false
        )
        editor.setAdjustment(.exposure, to: 1.5)

        try await waitUntil {
            try await store.loadAdjustments(documentID: document.id).exposure == 1.5
        }
        let saved = try await store.loadAdjustments(documentID: document.id)
        XCTAssertEqual(saved.exposure, 1.5)
        XCTAssertEqual(try Data(contentsOf: rawURL), original, "openInPlace + autosave must never touch the RAW original")
    }

    /// 3: a brand-new `PhotoDocumentStore` instance over the same root
    /// (standing in for an app relaunch) loads the adjustments a prior
    /// session autosaved.
    func testReopeningAFreshStoreInstanceLoadsTheAutosavedAdjustments() async throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rawURL = root.appendingPathComponent("fixture.ARW")
        try Data(repeating: 0x24, count: 4096).write(to: rawURL)

        let storeRoot = root.appendingPathComponent("Store")
        let store = PhotoDocumentStore(rootURL: storeRoot)
        let document = try await store.openInPlace(rawURL, bookmarkData: nil).document
        let editor = makeEditor(store: store)
        editor.open(
            photo: photo(for: document),
            sourceURL: document.workingURL,
            adjustments: .neutral,
            isReadOnly: false
        )
        editor.setAdjustment(.contrast, to: 12)
        let flushed = await editor.flushPendingEdits()
        XCTAssertTrue(flushed)

        let reopenedStore = PhotoDocumentStore(rootURL: storeRoot)
        let reopenedDocument = try await reopenedStore.loadDocument(id: document.id)
        let reopenedAdjustments = try await reopenedStore.loadAdjustments(documentID: reopenedDocument.id)
        XCTAssertEqual(reopenedAdjustments.contrast, 12)
    }

    /// 4: an app-copy document's sidecar is keyed by the document ID, and
    /// the editor is opened against the working copy — never the external
    /// source — which is exactly what `PadEditorModel.openEditor(for:)`
    /// must do for `.appCopy` mode.
    func testAppCopyEditorOpensAgainstTheWorkingCopyAndSidecarTracksTheDocumentID() async throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rawURL = root.appendingPathComponent("fixture.ARW")
        try Data(repeating: 0x11, count: 4096).write(to: rawURL)
        let originalSourceBytes = try Data(contentsOf: rawURL)

        let store = PhotoDocumentStore(rootURL: root.appendingPathComponent("Store"))
        let document = try await store.importCopy(of: rawURL, bookmarkData: nil).document
        XCTAssertEqual(document.storageMode, .appCopy)
        XCTAssertNotEqual(document.workingURL, rawURL)

        let editor = makeEditor(store: store)
        editor.open(
            photo: photo(for: document),
            sourceURL: document.workingURL,
            adjustments: .neutral,
            isReadOnly: false
        )
        XCTAssertEqual(editor.sourceURL, document.workingURL, "the editor must decode/preview the working copy, not the external source")
        XCTAssertNotEqual(editor.sourceURL, rawURL)

        editor.setAdjustment(.saturation, to: -20)
        let flushed = await editor.flushPendingEdits()
        XCTAssertTrue(flushed)

        let savedAdjustments = try await store.loadAdjustments(documentID: document.id)
        XCTAssertEqual(savedAdjustments.saturation, -20)
        // The sidecar is keyed by `document.id`, independent of the
        // external source's own path -- reopening the same document ID is
        // enough to find it again.
        let reloaded = try await store.loadAdjustments(documentID: document.id)
        XCTAssertEqual(reloaded.saturation, -20)
        // The external source was never touched by any of this.
        XCTAssertEqual(try Data(contentsOf: rawURL), originalSourceBytes)
    }

    /// 5: a save that fails is never reported as saved, and the on-disk
    /// sidecar never reflects the value that failed to write.
    func testSaveFailureIsNeverReportedAsSaved() async throws {
        let root = try makeFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rawURL = root.appendingPathComponent("fixture.ARW")
        try Data(repeating: 0x77, count: 4096).write(to: rawURL)
        let original = try Data(contentsOf: rawURL)

        let store = PhotoDocumentStore(rootURL: root.appendingPathComponent("Store"))
        let document = try await store.openInPlace(rawURL, bookmarkData: nil).document

        let editor = EditorSession()
        let renderer = NeverPreviewRenderer()
        editor.attach(dependencies: EditorDependencies(
            previewScheduler: PreviewScheduler(renderer: renderer),
            previewRenderer: renderer,
            loadAdjustments: { photo in
                try await store.loadAdjustments(documentID: photo.id.rawValue)
            },
            saveAdjustments: { _, _ in throw WriteFailure() }
        ))
        editor.open(
            photo: photo(for: document),
            sourceURL: document.workingURL,
            adjustments: .neutral,
            isReadOnly: false
        )
        editor.setAdjustment(.exposure, to: 0.8)

        let flushed = await editor.flushPendingEdits()
        XCTAssertFalse(flushed, "a failed write must be reported back to the caller, not swallowed")
        guard case .failed = editor.saveState else {
            XCTFail("expected saveState to be .failed after a throwing save, was \(editor.saveState)")
            return
        }

        let onDisk = try await store.loadAdjustments(documentID: document.id)
        XCTAssertEqual(onDisk.exposure, 0, "a failed save must not be visible on disk as the new value")
        XCTAssertEqual(try Data(contentsOf: rawURL), original)
    }
}
