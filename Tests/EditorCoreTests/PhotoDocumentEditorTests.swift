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

/// Fails only for URLs whose filename is in `failingFilenames` -- matched
/// by filename, not full path, since an `.appCopy` document's `workingURL`
/// is a copy under App storage with the same filename but a different
/// directory than the external source that was picked.
private struct SelectivelyFailingDecoder: RawDecoding {
    let identifier = DecoderIdentifier(kind: "fake-selective-fail", version: "1")
    let failingFilenames: Set<String>
    func supportsFile(at url: URL) -> Bool { true }
    func readMetadata(at url: URL) throws -> RawMetadata {
        if failingFilenames.contains(url.lastPathComponent) {
            throw RawDecodingError.unsupportedFormat(path: url.path)
        }
        return RawMetadata()
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
///
/// `waitUntilArrived(at:)` gives a test a *deterministic* way to know a
/// gated call has actually been entered (and is now blocked), instead of
/// guessing with a fixed `Task.sleep` -- a test drives the two operations it
/// cares about entirely off these signals, never off wall-clock time.
private final class GatedDecoder: RawDecoding, @unchecked Sendable {
    let identifier = DecoderIdentifier(kind: "fake-gated", version: "1")
    private let lock = NSLock()
    private var semaphores: [URL: DispatchSemaphore] = [:]
    private var arrived: Set<URL> = []
    private var arrivalContinuations: [URL: [CheckedContinuation<Void, Never>]] = [:]

    init(gatedURLs: [URL]) {
        for url in gatedURLs { semaphores[url] = DispatchSemaphore(value: 0) }
    }

    convenience init(gatedURL: URL) { self.init(gatedURLs: [gatedURL]) }

    func supportsFile(at url: URL) -> Bool { true }

    /// Runs `body` with `lock` held. A plain synchronous function, called
    /// from both sync and async contexts below -- keeping the lock/unlock
    /// pair themselves inside a non-async function is what avoids Swift 6's
    /// "unavailable from asynchronous contexts" diagnostic on `NSLock`,
    /// since neither call is textually inside an `async` function body.
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func readMetadata(at url: URL) throws -> RawMetadata {
        let (semaphore, continuations) = withLock {
            arrived.insert(url)
            let continuations = arrivalContinuations.removeValue(forKey: url) ?? []
            return (semaphores[url], continuations)
        }
        for continuation in continuations { continuation.resume() }
        semaphore?.wait()
        return RawMetadata()
    }

    func decode(_ request: RawDecodeRequest) throws -> DecodedRawImage {
        throw RawDecodingError.unsupportedFormat(path: request.url.path)
    }

    func release(_ url: URL) {
        let semaphore = withLock { semaphores[url] }
        semaphore?.signal()
    }

    /// Suspends until `readMetadata(at: url)` has actually been entered
    /// (and, if `url` is gated, is now blocked there).
    func waitUntilArrived(at url: URL) async {
        let alreadyArrived = withLock { arrived.contains(url) }
        guard !alreadyArrived else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resolvedImmediately = withLock { () -> Bool in
                if arrived.contains(url) { return true }
                arrivalContinuations[url, default: []].append(continuation)
                return false
            }
            if resolvedImmediately { continuation.resume() }
        }
    }
}

private struct NeverPreviewRenderer: PreviewRendering {
    func render(_ request: PreviewRequest) async throws -> PreviewImage {
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }
}

/// Local mirror of `PhotoDocumentStore`'s private on-disk shape for the
/// active-document pointer -- just enough to decode `documentID` back out
/// of whatever `ActivePointerWriteRecorder` intercepts. Coupled to the
/// store's `ActiveDocument.json` filename/format by construction: if that
/// ever changes, this (and every test relying on it) should fail loudly
/// rather than silently stop observing writes.
private struct ActivePointerProbe: Decodable {
    var documentID: UUID?
}

/// Thread-safe recorder that `Harness` wires into `PhotoDocumentStore`'s
/// `writeRecordData` seam to observe every write to the active-document
/// pointer file -- the real, durable one `PhotoDocumentEditor` now reads
/// and writes directly via `store.loadActiveDocumentID()`/
/// `saveActiveDocumentID(_:)`, not a separate in-memory or `UserDefaults`
/// stand-in. `@unchecked Sendable` plus an `NSLock` because the actor
/// invokes this closure from off the main actor, same reasoning as
/// `GatedDecoder` above.
private final class ActivePointerWriteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var writes: [UUID?] = []

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func record(_ id: UUID?) {
        withLock { writes.append(id) }
    }

    var snapshot: [UUID?] {
        withLock { writes }
    }

    func reset() {
        withLock { writes = [] }
    }
}

/// Lets a test make specific durable writes -- matched by a predicate on
/// the destination `URL` -- fail on demand, to exercise
/// `PhotoDocumentEditor`'s finalize-retry and durable-pointer-write gating
/// without needing real filesystem permission games. Thread-safe for the
/// same reason `ActivePointerWriteRecorder` is: the actor invokes the
/// wrapping closure off the main actor.
private final class WriteFailureInjector: @unchecked Sendable {
    private let lock = NSLock()
    private var predicate: ((Data, URL) -> Bool)?

    func shouldFail(_ data: Data, _ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return predicate?(data, url) ?? false
    }

    /// Every subsequent write matching `predicate` fails until this is
    /// called again (with `nil` to stop failing anything, or a new
    /// predicate to fail something else). Takes the data being written,
    /// not just the destination `URL`, since a document record's initial
    /// `.pending` commit and its later finalize-to-`.committed` rewrite
    /// share the exact same path -- only their content differs.
    func setPredicate(_ predicate: ((Data, URL) -> Bool)?) {
        lock.lock()
        defer { lock.unlock() }
        self.predicate = predicate
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
    var scopeAccessSucceeds = true
    var bookmarkCreationResult: Result<Data, Error> = .success(Data("bookmark".utf8))
    var resolveScopeResult: Result<ResolvedSecurityScope, Error>?
    private(set) var madeScopes: [FakeSecurityScopedResource] = []
    private(set) var resolvedScopes: [FakeSecurityScopedResource] = []
    private let activePointerWrites: ActivePointerWriteRecorder
    /// The URL `makeBookmark` was last called with -- the default
    /// `resolveScope` echoes this back, so a test that doesn't explicitly
    /// override `resolveScopeResult` gets the realistic behavior ("the
    /// bookmark resolves back to where it was created") rather than an
    /// unrelated placeholder URL that would spuriously look like the
    /// document moved.
    private(set) var lastBookmarkedURL: URL?
    /// Lets a test make a specific durable write fail transiently -- e.g.
    /// "the next write to the active-pointer file" or "every write to this
    /// document's record until told otherwise" -- to exercise the
    /// finalize/pointer-write retry-gating `PhotoDocumentEditor` is
    /// responsible for. `nil` (the default) never fails anything.
    let writeFailureInjector = WriteFailureInjector()

    init() {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoDocumentEditorTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let recorder = ActivePointerWriteRecorder()
        activePointerWrites = recorder
        let injector = writeFailureInjector
        store = PhotoDocumentStore(
            rootURL: rootURL.appendingPathComponent("Store", isDirectory: true),
            writeRecordData: { data, url, fileManager in
                if injector.shouldFail(data, url) {
                    struct InjectedWriteFailure: Error {}
                    throw InjectedWriteFailure()
                }
                if url.lastPathComponent == "ActiveDocument.json" {
                    let id = (try? JSONDecoder().decode(ActivePointerProbe.self, from: data))?.documentID
                    recorder.record(id)
                }
                try AtomicFileWriter.write(data, to: url, fileManager: fileManager)
            }
        )
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
                let url = self?.lastBookmarkedURL ?? URL(fileURLWithPath: "/resolved")
                let scope = FakeSecurityScopedResource(url: url, isAccessing: true)
                self?.resolvedScopes.append(scope)
                return ResolvedSecurityScope(resource: scope, isStale: false)
            },
            makeBookmark: { [weak self] url in
                self?.lastBookmarkedURL = url
                return try self?.bookmarkCreationResult.get() ?? Data()
            }
        )
    }

    func makeEditor() -> PhotoDocumentEditor {
        PhotoDocumentEditor(dependencies: dependencies)
    }

    /// Reads the real, durably persisted active-document pointer directly
    /// from `store` -- never a separate in-memory stand-in -- so a test
    /// observes exactly what the next launch's reconciliation would see.
    func loadActiveDocumentID() async -> UUID? {
        await store.loadActiveDocumentID()
    }

    /// Pre-seeds the durable active-document pointer before a test starts
    /// an editor, e.g. to simulate "the previous launch left this document
    /// active."
    func setActiveDocumentID(_ id: UUID?) async throws {
        try await store.saveActiveDocumentID(id)
    }

    /// Every write observed on the active-document pointer file since the
    /// last `resetSavedActiveDocumentIDs()` (or since this `Harness` was
    /// created), in order.
    var savedActiveDocumentIDs: [UUID?] {
        activePointerWrites.snapshot
    }

    func resetSavedActiveDocumentIDs() {
        activePointerWrites.reset()
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
        let activeID = await harness.loadActiveDocumentID()
        XCTAssertEqual(activeID, documentID)

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

    /// A resolve failure is transient (e.g. the external volume is
    /// temporarily offline) -- the active document pointer must survive it
    /// so a later retry (or the next launch) can still succeed, and the
    /// alert must stay safe.
    func testATransientResolveFailureShowsASafeErrorButNeverFabricatesADocumentAndKeepsTheActiveID() async throws {
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
        // Transient failure: the pointer must survive for a retry.
        let activeID = await harness.loadActiveDocumentID()
        XCTAssertEqual(activeID, documentID)

        // And the retry actually succeeds once the volume is back.
        harness.resolveScopeResult = nil
        let thirdEditor = harness.makeEditor()
        thirdEditor.performStartupSequence()
        try await waitUntil { thirdEditor.document != nil }
        XCTAssertEqual(thirdEditor.document?.id, documentID)

        // The document itself (and its sidecar) must survive untouched --
        // restoring an existing document never deletes user data on failure.
        let stillThere = try await harness.store.loadDocument(id: documentID)
        XCTAssertEqual(stillThere.id, documentID)
    }

    /// The one genuinely unrecoverable case -- the record itself is gone --
    /// is the only one that clears the active-document pointer, so a
    /// broken pointer is not retried forever.
    func testRestoreClearsTheActiveIDOnlyWhenTheRecordIsDefinitivelyGone() async throws {
        let harness = Harness()
        try await harness.setActiveDocumentID(UUID()) // never actually created
        let editor = harness.makeEditor()

        editor.performStartupSequence()
        try await waitUntil { editor.alert != nil }

        XCTAssertNil(editor.document)
        let activeID = await harness.loadActiveDocumentID()
        XCTAssertNil(activeID, "documentNotFound is definitive -- the pointer must be cleared")
    }

    /// A fresh user selection must win over startup restore even when both
    /// start together and the fresh open is still mid-flight (blocked at
    /// its own metadata gate, `document` still `nil`) by the time restore's
    /// logic would run. Restore must neither race it nor cancel it.
    func testFreshSelectionBeatsStartupRestoreEvenWhileStillMidFlight() async throws {
        let harness = Harness()
        let sourceURLA = harness.makeSourceFile(named: "a.ARW")
        let firstEditor = harness.makeEditor()
        firstEditor.beginSelecting(sourceURLA)
        firstEditor.beginOpeningPendingSelection(mode: .appCopy)
        try await waitUntil { firstEditor.document != nil }
        let documentAID = try XCTUnwrap(firstEditor.document?.id)

        let urlB = harness.makeSourceFile(named: "b.ARW")
        let gate = GatedDecoder(gatedURL: urlB)
        harness.decoder = gate
        let secondEditor = harness.makeEditor()

        // `performStartupSequence()` only captures a baseline and starts a
        // background `Task` -- it does not run reconciliation/restore
        // synchronously. Starting the fresh selection here, still in the
        // same synchronous call, guarantees its token is minted before
        // that background task can possibly begin, regardless of scheduling.
        secondEditor.performStartupSequence()
        secondEditor.beginSelecting(urlB)
        secondEditor.beginOpeningPendingSelection(mode: .inPlace)
        await gate.waitUntilArrived(at: urlB)

        // Restore must not have touched anything -- neither cancelling B's
        // still-in-flight open nor overwriting the active pointer with A.
        XCTAssertNil(secondEditor.document)
        XCTAssertTrue(secondEditor.isPreparingDocument, "B's own open must still be the one in progress")

        gate.release(urlB)
        try await waitUntil { secondEditor.document != nil }
        XCTAssertEqual(secondEditor.document?.sourceURL, urlB, "B must win -- its open was never cancelled by restore")
        XCTAssertNotEqual(secondEditor.document?.id, documentAID)
    }

    /// When a bookmark resolves somewhere other than the last persisted
    /// `workingURL` (e.g. a remounted volume), metadata decode and the
    /// editor's `sourceURL` must use exactly where it resolved to, and that
    /// location must be persisted so a later restore doesn't need to
    /// rediscover it.
    func testInPlaceRestoreUsesTheBookmarkResolvedURLWhenItDiffersFromThePersistedOne() async throws {
        let harness = Harness()
        let oldURL = harness.makeSourceFile(named: "old-location.ARW")
        let firstEditor = harness.makeEditor()
        firstEditor.beginSelecting(oldURL)
        firstEditor.beginOpeningPendingSelection(mode: .inPlace)
        try await waitUntil { firstEditor.document != nil }
        let documentID = try XCTUnwrap(firstEditor.document?.id)

        // The old location is gone; a new one, with the same bytes, exists.
        let newURL = harness.rootURL.appendingPathComponent("new-location.ARW")
        try FileManager.default.moveItem(at: oldURL, to: newURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))

        let relocatedScope = FakeSecurityScopedResource(url: newURL, isAccessing: true)
        harness.resolveScopeResult = .success(ResolvedSecurityScope(resource: relocatedScope, isStale: false))
        harness.bookmarkCreationResult = .success(Data("relocated-bookmark".utf8))

        let secondEditor = harness.makeEditor()
        secondEditor.performStartupSequence()
        try await waitUntil { secondEditor.document != nil }

        XCTAssertEqual(secondEditor.document?.workingURL, newURL)
        XCTAssertEqual(secondEditor.document?.sourceURL, newURL)
        XCTAssertEqual(secondEditor.editor.sourceURL, newURL, "the editor must decode/preview from where the bookmark actually resolved")

        // Persisted -- a later restore doesn't need to redo this work.
        let reloadedFromStore = try await harness.store.loadDocument(id: documentID)
        XCTAssertEqual(reloadedFromStore.workingURL, newURL)
        XCTAssertEqual(reloadedFromStore.sourceURL, newURL)
        XCTAssertEqual(reloadedFromStore.sourceBookmarkData, Data("relocated-bookmark".utf8))
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
        // Deterministically wait until the first operation has actually
        // reached (and is now blocked at) its metadata-decode gate, rather
        // than guessing how long that takes.
        await gate.waitUntilArrived(at: urlA)

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
        await gate.waitUntilArrived(at: urlA)

        editor.beginSelecting(urlB)
        editor.beginOpeningPendingSelection(mode: .inPlace)
        try await waitUntil { editor.document?.sourceURL == urlB }
        let documentB = try XCTUnwrap(editor.document)
        let scopeA = try XCTUnwrap(harness.madeScopes.first { $0.url == urlA })

        // The stale operation for A "fails" from A's point of view (its
        // decoder call unblocks and returns), which must not touch B. Wait
        // for A's own scope-stop -- the real, observable signal that its
        // supersede path actually ran -- instead of guessing a delay.
        gate.release(urlA)
        try await waitUntil { scopeA.stopCount == 1 }

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
        await gate.waitUntilArrived(at: urlA)

        editor.beginSelecting(urlB)
        editor.beginOpeningPendingSelection(mode: .inPlace)
        await gate.waitUntilArrived(at: urlB)
        let scopeA = try XCTUnwrap(harness.madeScopes.first { $0.url == urlA })

        // A's stale operation resolves first; B is still gated (confirmed
        // arrived above, and not yet released), so it cannot possibly have
        // committed yet. Wait for A's own scope-stop -- the real signal
        // that its supersede path has run -- rather than guessing a delay.
        gate.release(urlA)
        try await waitUntil { scopeA.stopCount == 1 }
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

    /// The two-phase switch itself: if the *new* document fails to finish
    /// preparing (here, its metadata decode fails), the document already
    /// open must be left exactly as it was -- still open, still editable,
    /// its scope still valid, the active pointer never having moved off it
    /// even momentarily -- and still restorable after a relaunch.
    func testSwitchingToADocumentThatFailsToPrepareLeavesTheOldOneFullyValidAndReopenable() async throws {
        let harness = Harness()
        let urlA = harness.makeSourceFile(named: "a.ARW")
        let urlB = harness.makeSourceFile(named: "b.ARW")
        harness.decoder = SelectivelyFailingDecoder(failingFilenames: ["b.ARW"])
        let editor = harness.makeEditor()

        editor.beginSelecting(urlA)
        editor.beginOpeningPendingSelection(mode: .appCopy)
        try await waitUntil { editor.document != nil }
        let documentA = try XCTUnwrap(editor.document)
        editor.editor.setAdjustment(.exposure, to: 0.4)
        XCTAssertTrue(editor.editor.saveState.isDirty)

        editor.beginSelecting(urlB)
        editor.beginOpeningPendingSelection(mode: .appCopy)
        try await waitUntil { editor.alert != nil }

        // A must still be exactly as it was.
        XCTAssertEqual(editor.document?.id, documentA.id, "A must still be the open document")
        XCTAssertEqual(editor.editor.photo?.id, PhotoID(documentA.id))
        XCTAssertEqual(editor.editor.adjustments.exposure, 0.4, "A's in-memory edit must survive")
        let activeID = await harness.loadActiveDocumentID()
        XCTAssertEqual(activeID, documentA.id, "the active pointer must still point at A, never nil in between")

        // The failed switch to B must not have left an orphaned copy behind.
        let documentsDirectory = harness.rootURL
            .appendingPathComponent("Store", isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: documentsDirectory.path)) ?? []
        XCTAssertEqual(entries.count, 1, "only A's copy should exist; B's failed copy must have been rolled back")

        // A's edit -- made before the failed switch -- can still be flushed
        // and, after a simulated relaunch, restored.
        let flushed = await editor.editor.flushPendingEdits()
        XCTAssertTrue(flushed)
        let thirdEditor = harness.makeEditor()
        thirdEditor.performStartupSequence()
        try await waitUntil { thirdEditor.document != nil }
        XCTAssertEqual(thirdEditor.document?.id, documentA.id)
        XCTAssertEqual(thirdEditor.editor.adjustments.exposure, 0.4)
    }

    // MARK: 3. Closing cancels a not-yet-committed open

    /// `closeCurrentDocument()` must cancel an open that is still preparing
    /// -- `document` still `nil` -- not just one that already committed.
    func testCloseCancelsAnOpenStillPreparingBeforeItEverCommits() async throws {
        let harness = Harness()
        let url = harness.makeSourceFile()
        let gate = GatedDecoder(gatedURL: url)
        harness.decoder = gate
        let editor = harness.makeEditor()

        editor.beginSelecting(url)
        editor.beginOpeningPendingSelection(mode: .inPlace)
        await gate.waitUntilArrived(at: url)
        XCTAssertNil(editor.document, "the open must still be mid-flight, not yet committed")
        let scope = try XCTUnwrap(harness.madeScopes.first { $0.url == url })

        let closed = await editor.closeCurrentDocument()
        XCTAssertTrue(closed, "nothing had actually committed yet, so close trivially succeeds")

        gate.release(url)
        try await waitUntil { scope.stopCount == 1 }

        XCTAssertNil(editor.document, "the pending open must never commit after close cancelled it")
        let activeID = await harness.loadActiveDocumentID()
        XCTAssertNil(activeID)
        XCTAssertFalse(editor.isPreparingDocument)
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

    // MARK: 5. Relinking a document with a missing bookmark

    /// A document created directly via the store with `bookmarkData: nil`
    /// stands in for one saved before bookmarks were mandatory for
    /// `.inPlace` documents -- the only realistic way one ends up without
    /// one today.
    private func makeUnbookmarkedInPlaceDocument(
        _ harness: Harness, sourceURL: URL, adjustments: PhotoAdjustments = .neutral
    ) async throws -> PhotoDocumentCreation {
        let creation = try await harness.store.openInPlace(sourceURL, bookmarkData: nil)
        await harness.store.finalizeCreation(creation)
        if adjustments != .neutral {
            try await harness.store.saveAdjustments(adjustments, documentID: creation.document.id)
        }
        return creation
    }

    func testMissingBookmarkShowsRelinkAndKeepsActiveIDAndAdjustments() async throws {
        let harness = Harness()
        let sourceURL = harness.makeSourceFile()
        let edited = PhotoAdjustments.neutral.setting(.exposure, to: 0.65)
        let creation = try await makeUnbookmarkedInPlaceDocument(harness, sourceURL: sourceURL, adjustments: edited)
        try await harness.setActiveDocumentID(creation.document.id)

        let editor = harness.makeEditor()
        editor.performStartupSequence()
        try await waitUntil { editor.pendingRelink != nil }

        XCTAssertNil(editor.document, "must not fake success by opening a neutral placeholder under a new ID")
        XCTAssertEqual(editor.pendingRelink?.documentID, creation.document.id)
        XCTAssertEqual(editor.pendingRelink?.sourceFingerprint, creation.document.sourceFingerprint)
        let activeID = await harness.loadActiveDocumentID()
        XCTAssertEqual(activeID, creation.document.id, "a missing bookmark must not clear the active pointer")
    }

    func testRelinkingToTheCorrectFileRestoresTheSameDocumentAndAdjustments() async throws {
        let harness = Harness()
        let sourceURL = harness.makeSourceFile()
        let edited = PhotoAdjustments.neutral.setting(.contrast, to: 15)
        let creation = try await makeUnbookmarkedInPlaceDocument(harness, sourceURL: sourceURL, adjustments: edited)
        try await harness.setActiveDocumentID(creation.document.id)

        let editor = harness.makeEditor()
        editor.performStartupSequence()
        try await waitUntil { editor.pendingRelink != nil }

        // The user picks the *same* file again from Files.
        editor.beginRelinkSelection(sourceURL)
        try await waitUntil { editor.document != nil }

        XCTAssertEqual(editor.document?.id, creation.document.id, "relink must reuse the existing document ID, never mint a new one")
        XCTAssertNil(editor.pendingRelink)
        XCTAssertEqual(editor.editor.adjustments.contrast, 15, "the existing sidecar's adjustments must carry over")
        let activeID = await harness.loadActiveDocumentID()
        XCTAssertEqual(activeID, creation.document.id)
    }

    func testRelinkingToTheWrongFileIsRejectedAndLeavesExistingDataUntouched() async throws {
        let harness = Harness()
        let sourceURL = harness.makeSourceFile(named: "original.ARW", pattern: 0xAA)
        let wrongURL = harness.makeSourceFile(named: "different.ARW", pattern: 0xBB)
        let edited = PhotoAdjustments.neutral.setting(.contrast, to: 15)
        let creation = try await makeUnbookmarkedInPlaceDocument(harness, sourceURL: sourceURL, adjustments: edited)
        try await harness.setActiveDocumentID(creation.document.id)

        let editor = harness.makeEditor()
        editor.performStartupSequence()
        try await waitUntil { editor.pendingRelink != nil }

        editor.beginRelinkSelection(wrongURL)
        try await waitUntil { editor.alert != nil }

        XCTAssertNil(editor.document, "a fingerprint-mismatched file must never be attached to the existing document")
        XCTAssertNotNil(editor.pendingRelink, "the prompt must stay so the user can try picking again")
        let activeID = await harness.loadActiveDocumentID()
        XCTAssertEqual(activeID, creation.document.id)

        let stillSaved = try await harness.store.loadAdjustments(documentID: creation.document.id)
        XCTAssertEqual(stillSaved.contrast, 15)
        let stillDocument = try await harness.store.loadDocument(id: creation.document.id)
        XCTAssertEqual(stillDocument.workingURL, sourceURL, "the record must still point at the original location")
    }

    /// Codex review: `cancelRelink()` must never permanently destroy the
    /// *only* way back into recovering this document -- there is no other
    /// affordance for a single-photo UI stuck on a missing bookmark than
    /// the relink prompt itself. Dismissing the file picker without
    /// picking a file leaves `pendingRelink` (and everything about the
    /// document) exactly as it was, so the same prompt is still there to
    /// try again -- matching what `cancelRelink()`'s own doc comment always
    /// promised, which the old implementation (clearing `pendingRelink`)
    /// silently broke.
    func testCancellingRelinkKeepsThePromptAvailableToTryAgain() async throws {
        let harness = Harness()
        let sourceURL = harness.makeSourceFile()
        let edited = PhotoAdjustments.neutral.setting(.exposure, to: 0.3)
        let creation = try await makeUnbookmarkedInPlaceDocument(harness, sourceURL: sourceURL, adjustments: edited)
        try await harness.setActiveDocumentID(creation.document.id)

        let editor = harness.makeEditor()
        editor.performStartupSequence()
        try await waitUntil { editor.pendingRelink != nil }

        editor.cancelRelink()

        XCTAssertNotNil(editor.pendingRelink, "the recovery prompt must survive a plain cancel, or it can never be reached again")
        XCTAssertEqual(editor.pendingRelink?.documentID, creation.document.id)
        XCTAssertNil(editor.document)
        let activeID = await harness.loadActiveDocumentID()
        XCTAssertEqual(activeID, creation.document.id)
        let stillSaved = try await harness.store.loadAdjustments(documentID: creation.document.id)
        XCTAssertEqual(stillSaved.exposure, 0.3)

        // And the prompt genuinely still works -- relinking the right file
        // after a cancel succeeds exactly as it would have without one.
        editor.beginRelinkSelection(sourceURL)
        try await waitUntil { editor.document != nil }
        XCTAssertEqual(editor.document?.id, creation.document.id)
        XCTAssertNil(editor.pendingRelink)
    }

    // MARK: 6. Restore scope ownership on every path

    /// Finds and overwrites every `.json` file under a document's sidecar
    /// directory with invalid content, so `loadAdjustments` throws --
    /// without needing to know `FileSidecarRepository`'s exact internal
    /// layout.
    private func corruptSidecar(for documentID: UUID, in harness: Harness) throws {
        let sidecarDirectory = harness.rootURL
            .appendingPathComponent("Store", isDirectory: true)
            .appendingPathComponent("Sidecars", isDirectory: true)
            .appendingPathComponent(documentID.uuidString, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: sidecarDirectory, includingPropertiesForKeys: nil) else {
            XCTFail("expected a sidecar directory to enumerate")
            return
        }
        var corruptedAny = false
        for case let file as URL in enumerator where file.pathExtension == "json" {
            try Data("not valid json".utf8).write(to: file)
            corruptedAny = true
        }
        XCTAssertTrue(corruptedAny, "expected to find at least one sidecar JSON file to corrupt")
    }

    func testInPlaceRestoreMetadataFailureStopsTheScopeExactlyOnce() async throws {
        let harness = Harness()
        let sourceURL = harness.makeSourceFile()
        let creation = try await makeUnbookmarkedInPlaceDocument(harness, sourceURL: sourceURL)
        // Give it a real bookmark this time -- this test is about a decode
        // failure, not a missing-bookmark relink.
        try await harness.store.updateSourceBookmark(Data("bookmark".utf8), documentID: creation.document.id)
        try await harness.setActiveDocumentID(creation.document.id)
        harness.decoder = FailingDecoder()

        let restoredScope = FakeSecurityScopedResource(url: sourceURL, isAccessing: true)
        harness.resolveScopeResult = .success(ResolvedSecurityScope(resource: restoredScope, isStale: false))

        let editor = harness.makeEditor()
        editor.performStartupSequence()
        try await waitUntil { editor.alert != nil }

        XCTAssertNil(editor.document)
        XCTAssertEqual(restoredScope.stopCount, 1)
    }

    func testInPlaceRestoreAdjustmentsLoadFailureStopsTheScopeExactlyOnce() async throws {
        let harness = Harness()
        let sourceURL = harness.makeSourceFile()
        let creation = try await makeUnbookmarkedInPlaceDocument(harness, sourceURL: sourceURL)
        try await harness.store.updateSourceBookmark(Data("bookmark".utf8), documentID: creation.document.id)
        try await harness.store.saveAdjustments(.neutral, documentID: creation.document.id)
        try corruptSidecar(for: creation.document.id, in: harness)
        try await harness.setActiveDocumentID(creation.document.id)

        let restoredScope = FakeSecurityScopedResource(url: sourceURL, isAccessing: true)
        harness.resolveScopeResult = .success(ResolvedSecurityScope(resource: restoredScope, isStale: false))

        let editor = harness.makeEditor()
        editor.performStartupSequence()
        try await waitUntil { editor.alert != nil }

        XCTAssertNil(editor.document)
        XCTAssertEqual(restoredScope.stopCount, 1)
    }

    func testRestoreScopeSupersededByAFreshOpenStopsExactlyOnce() async throws {
        let harness = Harness()
        let sourceURL = harness.makeSourceFile(named: "a.ARW")
        let creation = try await makeUnbookmarkedInPlaceDocument(harness, sourceURL: sourceURL)
        try await harness.store.updateSourceBookmark(Data("bookmark".utf8), documentID: creation.document.id)
        try await harness.setActiveDocumentID(creation.document.id)

        let restoreGate = GatedDecoder(gatedURL: sourceURL)
        harness.decoder = restoreGate
        let restoredScope = FakeSecurityScopedResource(url: sourceURL, isAccessing: true)
        harness.resolveScopeResult = .success(ResolvedSecurityScope(resource: restoredScope, isStale: false))

        let editor = harness.makeEditor()
        editor.performStartupSequence()
        await restoreGate.waitUntilArrived(at: sourceURL)

        // A fresh selection pre-empts the still-in-flight restore.
        let urlB = harness.makeSourceFile(named: "b.ARW")
        editor.beginSelecting(urlB)
        editor.beginOpeningPendingSelection(mode: .inPlace)
        try await waitUntil { editor.document?.sourceURL == urlB }

        restoreGate.release(sourceURL)
        try await waitUntil { restoredScope.stopCount == 1 }

        XCTAssertEqual(editor.document?.sourceURL, urlB, "the superseded restore must not clobber the fresh open")
        XCTAssertEqual(restoredScope.stopCount, 1)
    }

    func testSuccessfulRestoreScopeStaysOpenUntilClose() async throws {
        let harness = Harness()
        let sourceURL = harness.makeSourceFile()
        let creation = try await makeUnbookmarkedInPlaceDocument(harness, sourceURL: sourceURL)
        try await harness.store.updateSourceBookmark(Data("bookmark".utf8), documentID: creation.document.id)
        try await harness.setActiveDocumentID(creation.document.id)

        let restoredScope = FakeSecurityScopedResource(url: sourceURL, isAccessing: true)
        harness.resolveScopeResult = .success(ResolvedSecurityScope(resource: restoredScope, isStale: false))

        let editor = harness.makeEditor()
        editor.performStartupSequence()
        try await waitUntil { editor.document != nil }

        XCTAssertEqual(restoredScope.stopCount, 0, "the scope must still be held while the restored document is open")

        let closed = await editor.closeCurrentDocument()
        XCTAssertTrue(closed)
        XCTAssertEqual(restoredScope.stopCount, 1)
    }

    // MARK: 7. Active-document-ID write sequencing

    func testFailingToPrepareANewDocumentWritesNoActiveID() async throws {
        let harness = Harness()
        harness.decoder = FailingDecoder()
        let sourceURL = harness.makeSourceFile()
        let editor = harness.makeEditor()

        editor.beginSelecting(sourceURL)
        editor.beginOpeningPendingSelection(mode: .inPlace)
        try await waitUntil { editor.alert != nil }

        XCTAssertTrue(harness.savedActiveDocumentIDs.isEmpty)
    }

    func testFailingToFlushTheOldDocumentWritesNoActiveID() async throws {
        let harness = Harness()
        let urlA = harness.makeSourceFile(named: "a.ARW")
        let urlB = harness.makeSourceFile(named: "b.ARW")
        let editor = harness.makeEditor()

        editor.beginSelecting(urlA)
        editor.beginOpeningPendingSelection(mode: .inPlace)
        try await waitUntil { editor.document?.sourceURL == urlA }
        let documentAID = try XCTUnwrap(editor.document?.id)
        harness.resetSavedActiveDocumentIDs()

        // Force the next save to fail without touching file permissions
        // (unreliable when running as root in CI): pre-write a
        // newer-schema sidecar so `PhotoDocumentStore.saveAdjustments`
        // rejects overwriting it -- the same technique
        // `PhotoDocumentStoreTests.testSaveAdjustmentsRejectsANewerSchemaSidecarWithoutOverwriting`
        // uses.
        try await harness.store.saveAdjustments(.neutral, documentID: documentAID)
        let repositoryRoot = harness.rootURL
            .appendingPathComponent("Store", isDirectory: true)
            .appendingPathComponent("Sidecars", isDirectory: true)
            .appendingPathComponent(documentAID.uuidString, isDirectory: true)
        let repository = FileSidecarRepository(libraryRootURL: repositoryRoot)
        var newerSidecar = try XCTUnwrap(try repository.loadSidecar(for: PhotoID(documentAID)))
        newerSidecar.schemaVersion = PhotoSidecar.currentSchemaVersion + 1
        try repository.write(sidecar: newerSidecar)

        editor.editor.setAdjustment(.exposure, to: 0.5)

        editor.beginSelecting(urlB)
        editor.beginOpeningPendingSelection(mode: .inPlace)
        try await waitUntil {
            if case .failed = editor.editor.saveState { return true }
            return false
        }

        XCTAssertTrue(harness.savedActiveDocumentIDs.isEmpty, "a flush failure must abort the switch before any active-ID write")
        XCTAssertEqual(editor.document?.sourceURL, urlA, "the old document must remain open")
    }

    func testSuccessfulSwitchWritesExactlyOneNewIDWithNoNilInBetween() async throws {
        let harness = Harness()
        let urlA = harness.makeSourceFile(named: "a.ARW")
        let urlB = harness.makeSourceFile(named: "b.ARW")
        let editor = harness.makeEditor()

        editor.beginSelecting(urlA)
        editor.beginOpeningPendingSelection(mode: .inPlace)
        try await waitUntil { editor.document?.sourceURL == urlA }
        let documentAID = try XCTUnwrap(editor.document?.id)
        harness.resetSavedActiveDocumentIDs()

        editor.beginSelecting(urlB)
        editor.beginOpeningPendingSelection(mode: .inPlace)
        try await waitUntil { editor.document?.sourceURL == urlB }
        let documentBID = try XCTUnwrap(editor.document?.id)

        XCTAssertEqual(harness.savedActiveDocumentIDs, [documentBID], "exactly one write, directly to the new ID")
        XCTAssertNotEqual(documentAID, documentBID)
        XCTAssertFalse(harness.savedActiveDocumentIDs.contains(nil), "the active ID must never pass through nil while switching")
    }

    func testSuccessfulCloseWritesNilLast() async throws {
        let harness = Harness()
        let sourceURL = harness.makeSourceFile()
        let editor = harness.makeEditor()

        editor.beginSelecting(sourceURL)
        editor.beginOpeningPendingSelection(mode: .inPlace)
        try await waitUntil { editor.document != nil }

        let closed = await editor.closeCurrentDocument()
        XCTAssertTrue(closed)

        let lastWrite = try XCTUnwrap(harness.savedActiveDocumentIDs.last, "expected at least one active-ID write")
        XCTAssertNil(lastWrite, "the last write on a successful close must be nil")
    }

    // MARK: 8. Finalize durability gates close/switch (Codex round-3 review)

    /// If the durable commit write keeps failing, `closeCurrentDocument()`
    /// must refuse to close -- the document stays open, the active pointer
    /// is never cleared -- rather than letting the pointer move off a
    /// document that is still only `.pending` on disk. Once the write
    /// starts succeeding again, the very same close call this time
    /// actually closes it.
    func testCloseRefusesToProceedWhileTheCurrentDocumentsCommitCannotBeMadeDurable() async throws {
        let harness = Harness()
        let sourceURL = harness.makeSourceFile()

        // Fails only the *finalize* (committed) record write, identified
        // by content rather than path -- the initial `.pending` commit
        // inside the open itself must still succeed, or the document would
        // never open at all. This is what leaves `unfinalizedCreation` set
        // once the fresh open's own best-effort finalize attempt fails.
        harness.writeFailureInjector.setPredicate { data, url in
            guard url.pathExtension == "json", url.deletingLastPathComponent().lastPathComponent == "Records" else { return false }
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            return object?["lifecycleState"] as? String == "committed"
        }

        let editor = harness.makeEditor()
        editor.beginSelecting(sourceURL)
        editor.beginOpeningPendingSelection(mode: .inPlace)
        try await waitUntil { editor.document != nil }
        let documentID = try XCTUnwrap(editor.document?.id)

        let closed = await editor.closeCurrentDocument()
        XCTAssertFalse(closed, "must not report success while the commit still cannot be made durable")
        XCTAssertNotNil(editor.document, "the document must remain open")
        XCTAssertEqual(editor.document?.id, documentID)
        XCTAssertNotNil(editor.alert)

        let activeID = await harness.loadActiveDocumentID()
        XCTAssertEqual(activeID, documentID, "the active pointer must not have been cleared while the commit is still undurable")

        // The write starts succeeding again -- the very same close call
        // now finishes, retrying finalize first.
        harness.writeFailureInjector.setPredicate(nil)
        let retriedClose = await editor.closeCurrentDocument()
        XCTAssertTrue(retriedClose)
        XCTAssertNil(editor.document)
        let clearedID = await harness.loadActiveDocumentID()
        XCTAssertNil(clearedID)
    }

    /// Same gate, but for switching to a *different* document: the
    /// previously-open document's still-undurable commit must block the
    /// switch entirely -- the new document is rolled back, the old one
    /// stays open and untouched.
    func testSwitchingAwayFromAnUndurableDocumentIsRefusedAndTheNewOneIsRolledBack() async throws {
        let harness = Harness()
        let urlA = harness.makeSourceFile(named: "a.ARW")
        let urlB = harness.makeSourceFile(named: "b.ARW")

        // Same content-based targeting as above -- only A's finalize
        // (committed) write fails, not its initial pending commit.
        harness.writeFailureInjector.setPredicate { data, url in
            guard url.pathExtension == "json", url.deletingLastPathComponent().lastPathComponent == "Records" else { return false }
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            return object?["lifecycleState"] as? String == "committed"
        }

        let editor = harness.makeEditor()
        editor.beginSelecting(urlA)
        editor.beginOpeningPendingSelection(mode: .inPlace)
        try await waitUntil { editor.document != nil }
        let documentAID = try XCTUnwrap(editor.document?.id)

        editor.beginSelecting(urlB)
        editor.beginOpeningPendingSelection(mode: .inPlace)
        try await waitUntil { editor.alert != nil }

        XCTAssertEqual(editor.document?.id, documentAID, "A must still be the open document -- the switch to B must have been refused")
        XCTAssertEqual(editor.document?.sourceURL, urlA)

        // B's never-shown creation must have been rolled back -- no
        // leftover record for it.
        let recordsDirectory = harness.rootURL
            .appendingPathComponent("Store", isDirectory: true)
            .appendingPathComponent("Records", isDirectory: true)
        let recordNames = (try? FileManager.default.contentsOfDirectory(atPath: recordsDirectory.path))?
            .map { $0.replacingOccurrences(of: ".json", with: "") } ?? []
        XCTAssertFalse(recordNames.contains { $0 != documentAID.uuidString }, "B's record must not have survived a refused switch")

        let activeID = await harness.loadActiveDocumentID()
        XCTAssertEqual(activeID, documentAID)
    }

    /// If the *pointer* write specifically fails (independent of the
    /// finalize write succeeding), a fresh switch must be aborted the same
    /// way -- never treating a failed pointer write as though the hand-off
    /// became durable.
    func testSwitchAbortsWhenTheActivePointerWriteItselfFails() async throws {
        let harness = Harness()
        let urlA = harness.makeSourceFile(named: "a.ARW")
        let urlB = harness.makeSourceFile(named: "b.ARW")

        let editor = harness.makeEditor()
        editor.beginSelecting(urlA)
        editor.beginOpeningPendingSelection(mode: .inPlace)
        try await waitUntil { editor.document != nil }
        let documentAID = try XCTUnwrap(editor.document?.id)

        // A's own commit is left to succeed normally; only the pointer
        // write for B's switch is made to fail.
        harness.writeFailureInjector.setPredicate { _, url in
            url.lastPathComponent == "ActiveDocument.json"
        }

        editor.beginSelecting(urlB)
        editor.beginOpeningPendingSelection(mode: .inPlace)
        try await waitUntil { editor.alert != nil }

        XCTAssertEqual(editor.document?.id, documentAID, "A must still be open -- the pointer write failure must abort the switch to B")

        harness.writeFailureInjector.setPredicate(nil)
        let activeID = await harness.loadActiveDocumentID()
        XCTAssertEqual(activeID, documentAID, "the pointer must still durably say A -- it was never overwritten by the failed attempt to point at B")
    }
}
