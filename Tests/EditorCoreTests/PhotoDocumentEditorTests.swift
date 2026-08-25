import Foundation
import XCTest
@testable import EditorCore
import PhotoLibraryCore
import RawProcessingCore

// MARK: - Fakes

private final class FakeSecurityScopedResource: SecurityScopedResource {
    let url: URL
    private(set) var isAccessing: Bool
    private(set) var stopCount = 0

    init(url: URL, isAccessing: Bool = true) {
        self.url = url
        self.isAccessing = isAccessing
    }

    func stop() {
        stopCount += 1
        isAccessing = false
    }
}

private struct SucceedingDecoder: RawDecoding {
    let identifier = DecoderIdentifier(kind: "fake-ok", version: "1")
    func supportsFile(at url: URL) -> Bool { true }
    func readMetadata(at url: URL) throws -> RawMetadata { RawMetadata() }
    func decode(_ request: RawDecodeRequest) throws -> DecodedRawImage {
        throw RawDecodingError.unsupportedFormat(path: request.url.path)
    }
}

private struct FailingDecoder: RawDecoding {
    let identifier = DecoderIdentifier(kind: "fake-fail", version: "1")
    func supportsFile(at url: URL) -> Bool { true }
    func readMetadata(at url: URL) throws -> RawMetadata {
        throw RawDecodingError.unsupportedFormat(path: url.path)
    }
    func decode(_ request: RawDecodeRequest) throws -> DecodedRawImage {
        throw RawDecodingError.unsupportedFormat(path: request.url.path)
    }
}

/// Blocks `readMetadata` for each configured URL until that URL's
/// `release(_:)` is called, and returns immediately for any URL never
/// gated. This is what lets a test hold one or more "open" operations stuck
/// mid-flight, in whatever order it chooses, to prove how a later one
/// resolves against them.
private final class GatedDecoder: RawDecoding, @unchecked Sendable {
    let identifier = DecoderIdentifier(kind: "fake-gated", version: "1")
    private let lock = NSLock()
    private var semaphores: [URL: DispatchSemaphore] = [:]

    init(gatedURLs: [URL]) {
        for url in gatedURLs { semaphores[url] = DispatchSemaphore(value: 0) }
    }

    convenience init(gatedURL: URL) { self.init(gatedURLs: [gatedURL]) }

    func supportsFile(at url: URL) -> Bool { true }

    func readMetadata(at url: URL) throws -> RawMetadata {
        lock.lock()
        let semaphore = semaphores[url]
        lock.unlock()
        semaphore?.wait()
        return RawMetadata()
    }

    func decode(_ request: RawDecodeRequest) throws -> DecodedRawImage {
        throw RawDecodingError.unsupportedFormat(path: request.url.path)
    }

    func release(_ url: URL) {
        lock.lock()
        let semaphore = semaphores[url]
        lock.unlock()
        semaphore?.signal()
    }
}

private struct NeverPreviewRenderer: PreviewRendering {
    func render(_ request: PreviewRequest) async throws -> PreviewImage {
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }
}

/// A configurable, in-memory stand-in for every dependency
/// `PhotoDocumentEditor` needs, so its lifecycle logic — restore,
/// serialization, rollback — can be exercised without touching the sandbox
/// or a real security scope (neither of which exists in an XCTest process).
@MainActor
private final class Harness {
    let rootURL: URL
    let store: PhotoDocumentStore
    var decoder: any RawDecoding = SucceedingDecoder()
    var activeDocumentID: UUID?
    var scopeAccessSucceeds = true
    var bookmarkCreationResult: Result<Data, Error> = .success(Data("bookmark".utf8))
    var resolveScopeResult: Result<ResolvedSecurityScope, Error>?
    private(set) var madeScopes: [FakeSecurityScopedResource] = []
    private(set) var resolvedScopes: [FakeSecurityScopedResource] = []
    private(set) var savedActiveDocumentIDs: [UUID?] = []

    init() {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoDocumentEditorTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        store = PhotoDocumentStore(rootURL: rootURL.appendingPathComponent("Store", isDirectory: true))
    }

    func makeSourceFile(named name: String = "fixture.ARW", pattern: UInt8 = 0x5A) -> URL {
        let url = rootURL.appendingPathComponent(name)
        try? Data(repeating: pattern, count: 4_096).write(to: url)
        return url
    }

    @discardableResult
    func makeScope(for url: URL) -> FakeSecurityScopedResource {
        let scope = FakeSecurityScopedResource(url: url, isAccessing: scopeAccessSucceeds)
        madeScopes.append(scope)
        return scope
    }

    var dependencies: PhotoDocumentEditorDependencies {
        PhotoDocumentEditorDependencies(
            store: store,
            decoder: decoder,
            previewScheduler: PreviewScheduler(renderer: NeverPreviewRenderer()),
            previewRenderer: NeverPreviewRenderer(),
            makeScope: { [weak self] url in self?.makeScope(for: url) ?? FakeSecurityScopedResource(url: url) },
            resolveScope: { [weak self] data in
                if let result = self?.resolveScopeResult {
                    return try result.get()
                }
                let scope = FakeSecurityScopedResource(url: URL(fileURLWithPath: "/resolved"), isAccessing: true)
                self?.resolvedScopes.append(scope)
                return ResolvedSecurityScope(resource: scope, isStale: false)
            },
            makeBookmark: { [weak self] _ in try self?.bookmarkCreationResult.get() ?? Data() },
            loadActiveDocumentID: { [weak self] in self?.activeDocumentID },
            saveActiveDocumentID: { [weak self] id in
                self?.activeDocumentID = id
                self?.savedActiveDocumentIDs.append(id)
            }
        )
    }

    func makeEditor() -> PhotoDocumentEditor {
        PhotoDocumentEditor(dependencies: dependencies)
    }
}

private func waitUntil(
    timeout: TimeInterval = 3,
    _ condition: () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Timed out waiting for condition")
}

// MARK: - Tests

@MainActor
final class PhotoDocumentEditorTests: XCTestCase {

    // MARK: 1. Restore on launch

    func testAppCopyDocumentRestoresInAFreshModelAndStoreWithTheSameAdjustments() async throws {
        let harness = Harness()
        let sourceURL = harness.makeSourceFile()

        // First "launch": open, edit, and let it commit an active document ID.
        let firstEditor = harness.makeEditor()
        firstEditor.beginSelecting(sourceURL)
        firstEditor.beginOpeningPendingSelection(mode: .appCopy)
        try await waitUntil { firstEditor.document != nil }
        firstEditor.editor.setAdjustment(.exposure, to: 1.25)
        let flushed = await firstEditor.editor.flushPendingEdits()
        XCTAssertTrue(flushed)
        let documentID = try XCTUnwrap(firstEditor.document?.id)
        XCTAssertEqual(harness.activeDocumentID, documentID)

        // A brand-new model, over the same store root -- simulating a relaunch.
        let secondEditor = harness.makeEditor()
        secondEditor.performStartupSequence()
        try await waitUntil { secondEditor.document != nil }

        XCTAssertEqual(secondEditor.document?.id, documentID)
        XCTAssertEqual(secondEditor.editor.adjustments.exposure, 1.25)
    }

    func testInPlaceDocumentRestoresFromABookmarkAndKeepsTheScopeOpen() async throws {
        let harness = Harness()
        let sourceURL = harness.makeSourceFile()

        let firstEditor = harness.makeEditor()
        firstEditor.beginSelecting(sourceURL)
        firstEditor.beginOpeningPendingSelection(mode: .inPlace)
        try await waitUntil { firstEditor.document != nil }
        let documentID = try XCTUnwrap(firstEditor.document?.id)

        let restoredScope = FakeSecurityScopedResource(url: sourceURL, isAccessing: true)
        harness.resolveScopeResult = .success(ResolvedSecurityScope(resource: restoredScope, isStale: false))

        let secondEditor = harness.makeEditor()
        secondEditor.performStartupSequence()
        try await waitUntil { secondEditor.document != nil }

        XCTAssertEqual(secondEditor.document?.id, documentID)
        XCTAssertEqual(secondEditor.document?.storageMode, .inPlace)
        // The scope resolved for the restore must still be open -- it is
        // what backs continued reads of the in-place RAW.
        XCTAssertTrue(restoredScope.isAccessing)
        XCTAssertEqual(restoredScope.stopCount, 0)
    }

    func testStaleBookmarkIsRefreshedAndPersistedDuringRestore() async throws {
        let harness = Harness()
        let sourceURL = harness.makeSourceFile()

        let firstEditor = harness.makeEditor()
        firstEditor.beginSelecting(sourceURL)
        firstEditor.beginOpeningPendingSelection(mode: .inPlace)
        try await waitUntil { firstEditor.document != nil }
        let documentID = try XCTUnwrap(firstEditor.document?.id)
        let originalBookmark = try await harness.store.loadDocument(id: documentID).sourceBookmarkData

        let staleScope = FakeSecurityScopedResource(url: sourceURL, isAccessing: true)
        harness.resolveScopeResult = .success(ResolvedSecurityScope(resource: staleScope, isStale: true))
        harness.bookmarkCreationResult = .success(Data("refreshed-bookmark".utf8))

        let secondEditor = harness.makeEditor()
        secondEditor.performStartupSequence()
        try await waitUntil { secondEditor.document != nil }

        let reloaded = try await harness.store.loadDocument(id: documentID)
        XCTAssertEqual(reloaded.sourceBookmarkData, Data("refreshed-bookmark".utf8))
        XCTAssertNotEqual(reloaded.sourceBookmarkData, originalBookmark)
    }

    func testAnInvalidBookmarkShowsASafeErrorAndNeverFabricatesADocument() async throws {
        let harness = Harness()
        let sourceURL = harness.makeSourceFile()

        let firstEditor = harness.makeEditor()
        firstEditor.beginSelecting(sourceURL)
        firstEditor.beginOpeningPendingSelection(mode: .inPlace)
        try await waitUntil { firstEditor.document != nil }
        let documentID = try XCTUnwrap(firstEditor.document?.id)

        struct ResolveFailure: Error {}
        harness.resolveScopeResult = .failure(ResolveFailure())

        let secondEditor = harness.makeEditor()
        secondEditor.performStartupSequence()
        try await waitUntil { secondEditor.alert != nil }

        XCTAssertNil(secondEditor.document, "a failed restore must never fake success by opening something")
        XCTAssertNil(secondEditor.editor.photo, "no new/neutral document may be fabricated in EditorSession either")
        // Never silently retried against the same broken pointer forever.
        XCTAssertNil(harness.activeDocumentID)
        // The document itself (and its sidecar) must survive untouched --
        // restoring an existing document never deletes user data on failure.
        let stillThere = try await harness.store.loadDocument(id: documentID)
        XCTAssertEqual(stillThere.id, documentID)
    }

    // MARK: 2. Serializing overlapping opens

    func testOverlappingOpensOnlyCommitTheLatestSelection() async throws {
        let harness = Harness()
        let urlA = harness.makeSourceFile(named: "a.ARW", pattern: 0xAA)
        let urlB = harness.makeSourceFile(named: "b.ARW", pattern: 0xBB)
        let gate = GatedDecoder(gatedURL: urlA)
        harness.decoder = gate
        let editor = harness.makeEditor()

        editor.beginSelecting(urlA)
        editor.beginOpeningPendingSelection(mode: .inPlace)
        // Give the first operation a moment to actually reach the gate
        // before the second one preempts it.
        try await Task.sleep(for: .milliseconds(50))

        editor.beginSelecting(urlB)
        editor.beginOpeningPendingSelection(mode: .inPlace)
        try await waitUntil { editor.document?.sourceURL == urlB }

        let scopeA = try XCTUnwrap(harness.madeScopes.first { $0.url == urlA })
        let scopeB = try XCTUnwrap(harness.madeScopes.first { $0.url == urlB })
        XCTAssertEqual(scopeB.stopCount, 0, "the winning scope must still be held")

        // Let the stale first operation finish; it must discard itself.
        gate.release(urlA)
        try await waitUntil { scopeA.stopCount == 1 }

        XCTAssertEqual(editor.document?.sourceURL, urlB, "the superseded operation must not clobber the winner")
        XCTAssertEqual(scopeA.stopCount, 1, "the superseded operation's scope must be stopped exactly once")
        XCTAssertEqual(scopeB.stopCount, 0, "the winning operation's scope must still be exactly once-started, never stopped")
    }

    func testASupersededOperationsFailureDoesNotClearTheNewDocument() async throws {
        let harness = Harness()
        let urlA = harness.makeSourceFile(named: "a.ARW")
        let urlB = harness.makeSourceFile(named: "b.ARW")
        let gate = GatedDecoder(gatedURL: urlA)
        harness.decoder = gate
        let editor = harness.makeEditor()

        editor.beginSelecting(urlA)
        editor.beginOpeningPendingSelection(mode: .inPlace)
        try await Task.sleep(for: .milliseconds(50))

        editor.beginSelecting(urlB)
        editor.beginOpeningPendingSelection(mode: .inPlace)
        try await waitUntil { editor.document?.sourceURL == urlB }
        let documentB = try XCTUnwrap(editor.document)

        // The stale operation for A "fails" from A's point of view (its
        // decoder call unblocks and returns), which must not touch B.
        gate.release(urlA)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(editor.document?.id, documentB.id)
        XCTAssertFalse(editor.isPreparingDocument)
        XCTAssertNil(editor.alert, "a superseded operation must never pop an alert for the photo the user moved on from")
    }

    func testIsPreparingDocumentIsNotClearedEarlyByAStaleOperation() async throws {
        let harness = Harness()
        let urlA = harness.makeSourceFile(named: "a.ARW")
        let urlB = harness.makeSourceFile(named: "b.ARW")
        // Both A and B are gated, so the test controls exactly when each
        // one's decode resolves -- otherwise B (unblocked) would commit
        // before the test could observe it "still preparing".
        let gate = GatedDecoder(gatedURLs: [urlA, urlB])
        harness.decoder = gate
        let editor = harness.makeEditor()

        editor.beginSelecting(urlA)
        editor.beginOpeningPendingSelection(mode: .inPlace)
        try await Task.sleep(for: .milliseconds(30))

        editor.beginSelecting(urlB)
        editor.beginOpeningPendingSelection(mode: .inPlace)
        try await Task.sleep(for: .milliseconds(30))

        // A's stale operation resolves first; B is still gated, so it
        // cannot possibly have committed yet.
        gate.release(urlA)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(editor.isPreparingDocument, "B's own preparation must still be in progress")
        XCTAssertNil(editor.document, "A's stale completion must not have committed anything")

        gate.release(urlB)
        try await waitUntil { editor.document?.sourceURL == urlB }
        XCTAssertFalse(editor.isPreparingDocument)
    }

    /// A direct call to `closeCurrentDocument()` -- no concurrent open --
    /// flushes the dirty edit before tearing the session down.
    func testClosingADirtyDocumentFlushesBeforeClearingIt() async throws {
        let harness = Harness()
        let sourceURL = harness.makeSourceFile()
        let editor = harness.makeEditor()

        editor.beginSelecting(sourceURL)
        editor.beginOpeningPendingSelection(mode: .inPlace)
        try await waitUntil { editor.document != nil }
        let document = try XCTUnwrap(editor.document)
        editor.editor.setAdjustment(.exposure, to: 0.6)

        let closed = await editor.closeCurrentDocument()

        XCTAssertTrue(closed)
        XCTAssertNil(editor.document)
        XCTAssertNil(editor.editor.photo)
        let saved = try await harness.store.loadAdjustments(documentID: document.id)
        XCTAssertEqual(saved.exposure, 0.6)
    }

    /// Codex review: opening a second document while the first still has
    /// unsaved edits must never lose them, even though the caller never
    /// explicitly closed the first one first. This is the realistic version
    /// of "switching photos while dirty" -- a single, deterministic call
    /// chain (unlike a literal simultaneous close-vs-open button mash,
    /// which has two equally data-safe resolutions and is not what this
    /// property is about).
    func testOpeningASecondDocumentWhileTheFirstIsDirtyFlushesItFirst() async throws {
        let harness = Harness()
        let urlA = harness.makeSourceFile(named: "a.ARW")
        let urlB = harness.makeSourceFile(named: "b.ARW")
        let editor = harness.makeEditor()

        editor.beginSelecting(urlA)
        editor.beginOpeningPendingSelection(mode: .inPlace)
        try await waitUntil { editor.document?.sourceURL == urlA }
        let documentA = try XCTUnwrap(editor.document)
        editor.editor.setAdjustment(.exposure, to: 0.75)
        XCTAssertTrue(editor.editor.saveState.isDirty)
        let scopeA = try XCTUnwrap(harness.madeScopes.first { $0.url == urlA })

        editor.beginSelecting(urlB)
        editor.beginOpeningPendingSelection(mode: .inPlace)
        try await waitUntil { editor.document?.sourceURL == urlB }

        // A's edit reached disk before B ever took over `editor`.
        let savedA = try await harness.store.loadAdjustments(documentID: documentA.id)
        XCTAssertEqual(savedA.exposure, 0.75)
        XCTAssertEqual(editor.document?.sourceURL, urlB)
        XCTAssertEqual(editor.editor.photo?.id, PhotoID(try XCTUnwrap(editor.document?.id)))
        XCTAssertEqual(scopeA.stopCount, 1, "A's scope must be released exactly once when it is replaced")
    }

    // MARK: 4. Rollback of a document that never finished opening

    func testMetadataDecodeFailureForAFreshAppCopyLeavesNoRecordOrCopy() async throws {
        let harness = Harness()
        harness.decoder = FailingDecoder()
        let sourceURL = harness.makeSourceFile()
        let original = try Data(contentsOf: sourceURL)
        let editor = harness.makeEditor()

        editor.beginSelecting(sourceURL)
        editor.beginOpeningPendingSelection(mode: .appCopy)
        try await waitUntil { editor.alert != nil }

        XCTAssertNil(editor.document)
        let documentsDirectory = harness.rootURL
            .appendingPathComponent("Store", isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: documentsDirectory.path)) ?? []
        XCTAssertTrue(remaining.isEmpty, "a failed-to-open app copy must not leave a visible copy behind")
        XCTAssertEqual(try Data(contentsOf: sourceURL), original)
    }

    func testMetadataDecodeFailureForAFreshInPlaceDocumentNeverTouchesTheRAWAndLeavesNoRecord() async throws {
        let harness = Harness()
        harness.decoder = FailingDecoder()
        let sourceURL = harness.makeSourceFile()
        let original = try Data(contentsOf: sourceURL)
        let editor = harness.makeEditor()

        editor.beginSelecting(sourceURL)
        editor.beginOpeningPendingSelection(mode: .inPlace)
        try await waitUntil { editor.alert != nil }

        XCTAssertNil(editor.document)
        XCTAssertEqual(try Data(contentsOf: sourceURL), original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    func testRestoreFailureNeverDeletesAnExistingRecordOrSidecar() async throws {
        let harness = Harness()
        let sourceURL = harness.makeSourceFile()

        let firstEditor = harness.makeEditor()
        firstEditor.beginSelecting(sourceURL)
        firstEditor.beginOpeningPendingSelection(mode: .appCopy)
        try await waitUntil { firstEditor.document != nil }
        firstEditor.editor.setAdjustment(.exposure, to: 2)
        let flushed = await firstEditor.editor.flushPendingEdits()
        XCTAssertTrue(flushed)
        let documentID = try XCTUnwrap(firstEditor.document?.id)

        // Force the restore's metadata read to fail.
        harness.decoder = FailingDecoder()
        let secondEditor = harness.makeEditor()
        secondEditor.performStartupSequence()
        try await waitUntil { secondEditor.alert != nil }

        let stillThere = try await harness.store.loadDocument(id: documentID)
        XCTAssertEqual(stillThere.id, documentID)
        let stillSaved = try await harness.store.loadAdjustments(documentID: documentID)
        XCTAssertEqual(stillSaved.exposure, 2)
    }
}
