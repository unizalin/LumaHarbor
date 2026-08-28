import Foundation
import XCTest
@testable import PhotoLibraryCore
@testable import RawProcessingCore

/// A synthetic, in-memory walk for one root: no real directory enumeration,
/// no real files on disk. `nextPage()` only ever hands back what was built
/// up front, capped at the scanner's own batch size upstream (`FolderScanner`
/// slices `pages` before this type ever sees them isn't required here since
/// each page is already pre-sized).
private final class SyntheticCursor: FolderScanCursor, @unchecked Sendable {
    private let lock = NSLock()
    private var pages: [FolderScanPage]
    private var pageCallCount = 0

    init(pages: [FolderScanPage]) {
        self.pages = pages
    }

    var nextPageCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pageCallCount
    }

    func nextPage() -> FolderScanPage {
        lock.lock()
        defer { lock.unlock() }
        pageCallCount += 1
        return pages.isEmpty ? FolderScanPage(isAtEnd: true) : pages.removeFirst()
    }

    func close() {}
}

/// Dispatches to one `SyntheticCursor` per root, so a single `FolderScanner`
/// shared by every library in the service can still drive several distinct
/// 10,000-entry synthetic walks concurrently.
private struct SyntheticCursorFactory: FolderScanCursorFactory {
    let cursorsByRoot: [URL: SyntheticCursor]

    func makeCursor(root: URL, supportedExtensions: Set<String>, batchSize: Int) -> any FolderScanCursor {
        cursorsByRoot[root] ?? SyntheticCursor(pages: [FolderScanPage(isAtEnd: true)])
    }
}

/// Task 3 §13: three sources, 10,000 synthetic entries apiece, routed through
/// `PhotoLibraryService.scanLibraries` and the new `MultiSourceScanCoordinator`
/// -- proving volume, exactly-once delivery, the two-slot budget, and that
/// prune/`lastScanAt` safety survives being routed through the new
/// multi-source plumbing instead of a single `scan(libraryID:)` call.
///
/// Every synthetic entry's `url` points at a path that was never created on
/// disk. `FingerprintCalculator` therefore fails it, and it becomes a
/// `.photoFailed` event -- a real, individually-accounted-for per-photo
/// outcome through the unmodified production pipeline (spec §10), not a
/// shortcut around it. That is what makes 30,000 entries cheap: no file I/O,
/// no RAW decode, just 30,000 real (fast) failed `stat` calls plus 30,000
/// real backpressured send/receive round trips through the exact same
/// `AcknowledgedAsyncChannel` a single-source scan already uses. A scan
/// completing this way is still a *successful* scan (`wasCancelled == false`)
/// -- that only depends on whether the run was cancelled or superseded, not
/// on how many individual files failed -- so `lastScanAt` and pruning both
/// still exercise their real, unmodified gates.
final class MultiSourceBoundedScanTests: TemporaryDirectoryTestCase {
    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 10,
        _ condition: @Sendable () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for \(description)")
    }

    private func addLibrary(
        _ service: PhotoLibraryService,
        at url: URL,
        displayName: String
    ) async throws -> LibraryFolder {
        do {
            return try await service.addLibrary(at: url, displayName: displayName)
        } catch let error as LibraryError {
            if case .bookmark = error {
                throw XCTSkip("This host can't create security-scoped bookmarks: \(error)")
            }
            throw error
        }
    }

    /// `count` synthetic `ScannedFile`s under `root`, chunked into
    /// `FolderScanPage`s of `pageSize`, terminated by an empty `isAtEnd` page
    /// -- exactly the shape `FileManagerFolderScanCursor` itself produces.
    private func syntheticPages(root: URL, sourceTag: String, count: Int, pageSize: Int) -> [FolderScanPage] {
        var pages: [FolderScanPage] = []
        var remaining = count
        var index = 0
        while remaining > 0 {
            let thisPageCount = min(pageSize, remaining)
            var files: [ScannedFile] = []
            files.reserveCapacity(thisPageCount)
            for _ in 0..<thisPageCount {
                let relativePath = "\(sourceTag)/file-\(String(format: "%05d", index)).ARW"
                files.append(ScannedFile(
                    url: root.appendingPathComponent(relativePath),
                    relativePath: relativePath,
                    fileSize: 128
                ))
                index += 1
            }
            pages.append(FolderScanPage(files: files))
            remaining -= thisPageCount
        }
        pages.append(FolderScanPage(isAtEnd: true))
        return pages
    }

    // MARK: - 3 x 10,000 volume, concurrency and backpressure

    func testThreeSourcesTenThousandEachArriveExactlyOnceWithBoundedConcurrency() async throws {
        let perSourceCount = 10_000
        let rootA = try makeSubdirectory("VolumeRootA")
        let rootB = try makeSubdirectory("VolumeRootB")
        let rootC = try makeSubdirectory("VolumeRootC")

        let cursorA = SyntheticCursor(pages: syntheticPages(root: rootA, sourceTag: "A", count: perSourceCount, pageSize: 100))
        let cursorB = SyntheticCursor(pages: syntheticPages(root: rootB, sourceTag: "B", count: perSourceCount, pageSize: 100))
        let cursorC = SyntheticCursor(pages: syntheticPages(root: rootC, sourceTag: "C", count: perSourceCount, pageSize: 100))
        let factory = SyntheticCursorFactory(cursorsByRoot: [rootA: cursorA, rootB: cursorB, rootC: cursorC])

        let service = try PhotoLibraryService(
            locations: ApplicationSupportLocations(baseURL: try makeSubdirectory("VolumeAppSupport")),
            decoder: GatedScanDecoder(),
            scanner: FolderScanner(batchSize: 100, cursorFactory: factory)
        )

        let libraryA = try await addLibrary(service, at: rootA, displayName: "Volume A")
        let libraryB = try await addLibrary(service, at: rootB, displayName: "Volume B")
        let libraryC = try await addLibrary(service, at: rootC, displayName: "Volume C")

        // A stale row pre-existing in A's index, never re-seen by any of A's
        // 10,000 synthetic entries: a *successfully completing* scan (spec
        // §9) must still prune it, exactly as an unmodified single-source
        // scan would.
        let staleAssetID = PhotoID()
        let indexStore = await service.indexStore
        try indexStore.upsert(photos: [
            PhotoAsset(
                id: staleAssetID,
                libraryID: libraryA.id,
                relativePath: "A/deleted-before-rescan.ARW",
                fingerprint: FileFingerprint(fileSize: 1, edgeDigest: "stale"),
                lastSeenAt: Date().addingTimeInterval(-3600)
            )
        ])

        actor Collector {
            private var seen: Set<String> = []
            private(set) var duplicateCount = 0
            private var activeSources: Set<LibraryID> = []
            private(set) var maximumActiveSources = 0
            private var finishedResults: [LibraryID: LibraryScanResult] = [:]

            func record(libraryID: LibraryID, event: LibraryScanEvent) {
                switch event {
                case .started:
                    activeSources.insert(libraryID)
                    maximumActiveSources = max(maximumActiveSources, activeSources.count)
                case .photoFailed(let relativePath, _):
                    let key = "\(libraryID.description)/\(relativePath)"
                    if !seen.insert(key).inserted { duplicateCount += 1 }
                case .photosIndexed:
                    break
                case .finished(let result):
                    finishedResults[libraryID] = result
                    activeSources.remove(libraryID)
                case .failed:
                    activeSources.remove(libraryID)
                }
            }

            var seenCount: Int { seen.count }
            var results: [LibraryID: LibraryScanResult] { finishedResults }
        }

        let collector = Collector()
        await service.scanLibraries(
            [libraryA.id, libraryB.id, libraryC.id],
            selectedLibraryID: libraryA.id
        ) { libraryID, event in
            await collector.record(libraryID: libraryID, event: event)
        }

        // 1 & 2: every (LibraryID, relativePath) arrived exactly once.
        let seenCount = await collector.seenCount
        let duplicateCount = await collector.duplicateCount
        XCTAssertEqual(seenCount, perSourceCount * 3, "Not every synthetic entry arrived exactly once")
        XCTAssertEqual(duplicateCount, 0, "A synthetic entry arrived more than once")

        // 3 & 5: the coordinator's two-slot budget was honoured -- the third
        // source could only ever have started once one of the first two
        // slots freed.
        let maximumActiveSources = await collector.maximumActiveSources
        XCTAssertLessThanOrEqual(maximumActiveSources, 2, "More than two sources scanned concurrently")

        // 4: each underlying pipeline's own retained-batch bound is
        // untouched -- `AcknowledgedAsyncChannel` still holds at most one
        // parked, undelivered event per source, since `scanLibraries` awaits
        // `onEvent` for every event before requesting the next one (no
        // buffering bridge of its own).
        for cursor in [cursorA, cursorB, cursorC] {
            // Every page was actually consumed to the terminal `isAtEnd`
            // page -- proof the walk ran to completion under backpressure
            // rather than silently truncating.
            XCTAssertGreaterThanOrEqual(
                cursor.nextPageCallCount, perSourceCount / 100 + 1,
                "A source's cursor was not driven to completion"
            )
        }

        // 9: every source completed successfully (none cancelled), so each
        // must have its own `lastScanAt` recorded.
        let results = await collector.results
        for libraryID in [libraryA.id, libraryB.id, libraryC.id] {
            let result = try XCTUnwrap(results[libraryID], "Missing a finished event for \(libraryID)")
            XCTAssertFalse(result.wasCancelled)
            XCTAssertEqual(result.failedCount, perSourceCount)
            let folder = await service.library(id: libraryID)
            XCTAssertNotNil(folder?.lastScanAt, "A successfully completed source did not record lastScanAt")
        }

        // The stale pre-existing row in A, never re-seen by any of the
        // 30,000 synthetic entries, must have been pruned by A's successful
        // completion.
        let survivorsInA = try await service.photos(inLibrary: libraryA.id)
        XCTAssertFalse(
            survivorsInA.contains { $0.id == staleAssetID },
            "A successfully completed scan failed to prune a row it never saw again"
        )
    }

    // MARK: - Cancellation never prunes

    func testCancellingAMultiSourceScanNeverPrunesTheStillInFlightSources() async throws {
        let rootB = try makeSubdirectory("CancelRootB")
        let rootC = try makeSubdirectory("CancelRootC")

        let gate = InspectionGate()
        let decoder = GatedScanDecoder()
        decoder.gate = gate
        // Every file across both sources stalls: this test only cares that
        // cancelling the whole multi-source run leaves both still-in-flight
        // sources untouched, not about partial progress within either.
        decoder.gateAfterFileCount = 0

        let service = try PhotoLibraryService(
            locations: ApplicationSupportLocations(baseURL: try makeSubdirectory("CancelAppSupport")),
            decoder: decoder,
            scanner: FolderScanner(batchSize: 1)
        )

        for name in ["one.ARW", "two.ARW"] {
            try writeFile(Data("cancel test bytes".utf8), at: rootB.appendingPathComponent(name))
            try writeFile(Data("cancel test bytes".utf8), at: rootC.appendingPathComponent(name))
        }

        let libraryB = try await addLibrary(service, at: rootB, displayName: "Cancel B")
        let libraryC = try await addLibrary(service, at: rootC, displayName: "Cancel C")

        // A stale row in each: cancellation must leave both exactly as they
        // are, never mistaking "not re-seen because the scan never got that
        // far" for "genuinely gone" (spec §11).
        let indexStore = await service.indexStore
        for libraryID in [libraryB.id, libraryC.id] {
            try indexStore.upsert(photos: [
                PhotoAsset(
                    id: PhotoID(),
                    libraryID: libraryID,
                    relativePath: "pre-existing.ARW",
                    fingerprint: FileFingerprint(fileSize: 1, edgeDigest: "stale"),
                    lastSeenAt: Date().addingTimeInterval(-3600)
                )
            ])
        }
        let beforeB = try await service.photos(inLibrary: libraryB.id)
        let beforeC = try await service.photos(inLibrary: libraryC.id)

        let runTask = Task {
            await service.scanLibraries([libraryB.id, libraryC.id], selectedLibraryID: nil) { _, _ in }
        }

        await waitUntil("both sources to stall inside inspection") { gate.started >= 2 }
        runTask.cancel()
        gate.release()
        await runTask.value

        for (libraryID, before) in [(libraryB.id, beforeB), (libraryC.id, beforeC)] {
            let after = try await service.photos(inLibrary: libraryID)
            XCTAssertEqual(
                Set(after.map(\.id)), Set(before.map(\.id)),
                "A cancelled multi-source scan pruned or altered rows for \(libraryID)"
            )
            let folder = await service.library(id: libraryID)
            XCTAssertNil(folder?.lastScanAt, "A cancelled scan recorded a successful lastScanAt")
        }
    }

    // MARK: - Selected-source priority, end to end

    func testSelectedSourcePriorityIsHonoredThroughScanLibraries() async throws {
        let rootBlockerA = try makeSubdirectory("PriorityBlockerA")
        let rootBlockerB = try makeSubdirectory("PriorityBlockerB")
        let rootNormal = try makeSubdirectory("PriorityNormal")
        let rootSelected = try makeSubdirectory("PrioritySelected")

        let gate = InspectionGate()
        let decoder = GatedScanDecoder()
        decoder.gate = gate
        decoder.gateAfterFileCount = 0

        let service = try PhotoLibraryService(
            locations: ApplicationSupportLocations(baseURL: try makeSubdirectory("PriorityAppSupport")),
            decoder: decoder,
            scanner: FolderScanner(batchSize: 1)
        )

        for root in [rootBlockerA, rootBlockerB, rootNormal, rootSelected] {
            try writeFile(Data("priority test bytes".utf8), at: root.appendingPathComponent("one.ARW"))
        }

        let blockerA = try await addLibrary(service, at: rootBlockerA, displayName: "Blocker A")
        let blockerB = try await addLibrary(service, at: rootBlockerB, displayName: "Blocker B")
        let normalSource = try await addLibrary(service, at: rootNormal, displayName: "Normal")
        let selectedSource = try await addLibrary(service, at: rootSelected, displayName: "Selected")

        actor StartOrder {
            private(set) var order: [LibraryID] = []
            func record(_ id: LibraryID) { order.append(id) }
        }
        let startOrder = StartOrder()

        func run(_ libraryID: LibraryID, selected: LibraryID?) -> Task<Void, Never> {
            Task {
                await service.scanLibraries([libraryID], selectedLibraryID: selected) { id, event in
                    if case .started = event { await startOrder.record(id) }
                }
            }
        }

        // Occupy both slots first, sequentially, so their relative order is
        // deterministic before the priority pair ever arrives.
        let blockerTaskA = run(blockerA.id, selected: nil)
        await waitUntil("blocker A to start") { gate.started >= 1 }
        let blockerTaskB = run(blockerB.id, selected: nil)
        await waitUntil("blocker B to start") { gate.started >= 2 }

        // `normalSource` queues first; `selectedSource` arrives afterwards
        // but with priority, and must still be scheduled first once a slot
        // frees.
        let normalTask = run(normalSource.id, selected: nil)
        try? await Task.sleep(for: .milliseconds(50))
        let selectedTask = run(selectedSource.id, selected: selectedSource.id)

        gate.release()
        await waitUntil("both queued sources to have started") { gate.started >= 4 }
        gate.release()

        await blockerTaskA.value
        await blockerTaskB.value
        await normalTask.value
        await selectedTask.value

        let order = await startOrder.order
        let normalIndex = try XCTUnwrap(order.firstIndex(of: normalSource.id))
        let selectedIndex = try XCTUnwrap(order.firstIndex(of: selectedSource.id))
        XCTAssertLessThan(
            selectedIndex, normalIndex,
            "The selected-priority source must start before the earlier-queued normal source"
        )
    }
}
