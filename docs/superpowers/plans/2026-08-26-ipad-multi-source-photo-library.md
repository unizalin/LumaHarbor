# iPad Multi-Source Photo Library Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an iPad photo library that aggregates multiple authorised RAW folders, browses them through a paged adaptive sidebar/grid, survives offline sources, and opens indexed photos in the existing non-destructive editor.

**Architecture:** Extend the existing `PhotoLibraryCore` SQLite, bookmark, bounded-scan and thumbnail systems instead of creating an iPad-only data layer. Keep the testable browser state machine in `EditorCore` as `LibraryBrowserSession`; the nested iPad app supplies a `PadLibraryModel` typealias and SwiftUI shell. Preserve `PhotoDocumentEditor` as the only document/open/autosave state machine.

**Tech Stack:** Swift 5.9, Swift Concurrency with complete strict checking, SQLite3, SwiftUI, Core Image `CIRAWFilter`, XCTest, security-scoped bookmarks, existing LumaHarbor bounded scan and LRU cache infrastructure.

## Global Constraints

- Minimum platforms remain macOS 14 and iOS 17; the real-device completion gate requires an M1 or newer iPad.
- The package remains dependency-free; do not add third-party packages.
- RAW files are immutable. No code path may overwrite, rename, move or delete a source RAW.
- The library accepts RAW formats that the platform `CIRAWFilter` can decode; Sony `.ARW` is the mandatory real-fixture format.
- One library aggregates multiple sources. Exact duplicates in distinct sources remain distinct assets; reliably detected parent/child source overlap is rejected.
- Offline sources keep their local index and cached thumbnails. Editing and export require the original or an explicit existing App copy.
- SQLite, bookmarks and thumbnail caches are local, disposable or rebuildable; portable edits remain in sidecars or `PhotoDocumentStore` records.
- Every scan layer retains at most two discovered batches; the app runs at most two source scans concurrently.
- Production page size is 100 and must never exceed 200. Queries use stable keyset cursors, not high offsets.
- iPad thumbnail cache defaults to 2 GiB and accepts configured budgets from 512 MiB through 10 GiB. Existing Mac defaults do not change.
- User-facing strings are localised in English and Traditional Chinese. Status is never conveyed by colour alone and touch targets are at least 44×44 pt.
- Logs, reports and diagnostics must not expose private absolute paths. Real-hardware items not executed are `NOT RUN`, never PASS.
- Work task-by-task. Do not push, merge or rebase unless the user separately authorises it.
- Tasks 1–8 may proceed while Task 8 hardware evidence is pending. Task 9 requires the reviewed iPad vertical-slice runner to be landed or explicitly integrated first; do not duplicate or silently replace that runner.

## File Structure

| File | Responsibility |
|---|---|
| `Sources/PhotoLibraryCore/Model/LibraryQuery.swift` | Scope, sort, lazy folder nodes, keyset cursor and page value types |
| `Sources/PhotoLibraryCore/Model/LibraryFolder.swift` | Source kind and connection-state public model |
| `Sources/PhotoLibraryCore/Scanning/LibrarySourceIdentity.swift` | Stable source identity and overlap decisions |
| `Sources/PhotoLibraryCore/Index/PhotoIndexStore.swift` | Schema v2 migration and paged cross-source queries |
| `Sources/PhotoLibraryCore/Service/MultiSourceScanCoordinator.swift` | Two-slot, one-scan-per-source scheduling |
| `Sources/PhotoLibraryCore/Service/PhotoLibraryService.swift` | Source lifecycle, query facade and scan integration |
| `Sources/PhotoLibraryCore/Documents/PhotoDocumentStore.swift` | Enumerate and open committed App-copy documents |
| `Sources/EditorCore/LibraryBrowserDependencies.swift` | Sendable closure boundary for browser tests and production composition |
| `Sources/EditorCore/LibraryBrowserSession.swift` | Main-actor query, paging, selection, restoration and progress state machine |
| `Sources/EditorCore/PhotoDocumentEditor.swift` | Open an already indexed source or committed App-copy without repeating the import-choice dialog |
| `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadAppServices.swift` | Compose core services once for the iPad app lifetime |
| `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadLibraryModel.swift` | Stable iPad typealias to `LibraryBrowserSession` |
| `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadLibraryView.swift` | Adaptive library container and toolbar |
| `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadLibrarySidebar.swift` | Smart scopes, sources, folder tree and source progress |
| `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadLibraryGrid.swift` | Lazy paged grid, restoration anchor and empty/error states |
| `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadThumbnailCell.swift` | Thumbnail loading, badges and accessibility semantics |
| `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadLibrarySettingsView.swift` | iPad thumbnail-cache budget control |
| `Tests/PhotoLibraryCoreTests/*` | Schema, query, source identity, coordinator and document projection tests |
| `Tests/EditorCoreTests/LibraryBrowserSessionTests.swift` | Browser generation, paging, selection and offline gates |
| `Tests/EditorCoreTests/PhotoDocumentEditorLibraryOpenTests.swift` | Indexed source and App-copy open transitions |
| `Scripts/run-ipad-library-acceptance.zsh` | Fail-fast automated acceptance and privacy evidence |
| `docs/testing/reports/2026-08-26-ipad-multi-source-library.md` | Automated and real-device results |

---

### Task 1: Add SQLite schema v2 and stable paged cross-source queries

**Files:**
- Create: `Sources/PhotoLibraryCore/Model/LibraryQuery.swift`
- Modify: `Sources/PhotoLibraryCore/Index/PhotoIndexStore.swift`
- Modify: `Sources/PhotoLibraryCore/Model/PhotoAsset.swift`
- Test: `Tests/PhotoLibraryCoreTests/PhotoIndexMigrationTests.swift`
- Test: `Tests/PhotoLibraryCoreTests/PhotoIndexQueryTests.swift`

**Interfaces:**
- Consumes: existing `LibraryID`, `PhotoID`, `PhotoAsset`, `SQLiteDatabase`.
- Produces: `LibraryScope`, `PhotoSort`, `LibraryQuery`, `LibraryDirectoryNode`, `PhotoPageCursor`, `PhotoPage`, `PhotoIndexStore.page(matching:after:limit:)`, `childDirectories(libraryID:parent:)`, `setEditState(for:hasEdits:lastEditAt:)`, and `PhotoAsset.lastEditAt`.

- [ ] **Step 1: Write failing schema migration tests**

Create a schema-v1 fixture database, open it through `PhotoIndexStore`, and prove v2 columns survive reopen and a forced migration failure leaves schema v1 intact. Use these exact assertions:

```swift
func testOpeningV1DatabaseMigratesAtomicallyToV2() throws {
    let url = temporaryDirectory.appendingPathComponent("library.sqlite")
    try makeSchemaV1Database(at: url, photoCount: 2)

    let store = try PhotoIndexStore(databaseURL: url)

    XCTAssertEqual(PhotoIndexStore.schemaVersion, 2)
    XCTAssertEqual(try store.photoCount(inLibrary: fixtureLibraryID), 2)
    XCTAssertEqual(try store.page(
        matching: LibraryQuery(scope: .all, sort: .captureDateDescending),
        after: nil,
        limit: 100
    ).photos.count, 2)
}

func testMigrationFailureRollsBackEveryV2Change() throws {
    let url = temporaryDirectory.appendingPathComponent("library.sqlite")
    try makeSchemaV1Database(at: url, photoCount: 1)
    XCTAssertThrowsError(try PhotoIndexStore(
        databaseURL: url,
        migrationHook: { throw TestError.injected }
    ))
    XCTAssertEqual(try readSchemaVersion(at: url), 1)
    XCTAssertFalse(try columnExists("photo", "filename_normalized", at: url))
}
```

- [ ] **Step 2: Run migration tests and confirm RED**

Run:

```bash
swift test --filter PhotoIndexMigrationTests
```

Expected: compile failure because schema v2, the migration seam and query types do not exist.

- [ ] **Step 3: Define query and page value types**

Create `LibraryQuery.swift` with public `Sendable, Equatable` types. `PhotoPageCursor` must carry the selected sort's nullable date or normalized filename plus `PhotoID`; it must not carry a URL or absolute path.

```swift
public enum LibraryScope: Sendable, Equatable {
    case all
    case source(LibraryID)
    case folder(libraryID: LibraryID, relativePath: String)
    case appStorage
    case recentlyEdited
}

public enum PhotoSort: Sendable, Equatable {
    case captureDateDescending
    case captureDateAscending
    case filenameAscending
    case filenameDescending
}

public struct LibraryQuery: Sendable, Equatable {
    public var scope: LibraryScope
    public var filenameSearch: String?
    public var sort: PhotoSort

    public init(scope: LibraryScope, filenameSearch: String? = nil, sort: PhotoSort) {
        self.scope = scope
        self.filenameSearch = filenameSearch
        self.sort = sort
    }
}

public struct PhotoPageCursor: Sendable, Equatable {
    public var dateKey: Date?
    public var filenameKey: String?
    public var photoID: PhotoID
}

public struct PhotoPage: Sendable, Equatable {
    public var photos: [PhotoAsset]
    public var nextCursor: PhotoPageCursor?
}

public struct LibraryDirectoryNode: Sendable, Equatable, Identifiable {
    public var id: String { "\(libraryID.description)/\(relativePath)" }
    public var libraryID: LibraryID
    public var relativePath: String
    public var displayName: String
    public var childCount: Int
}
```

- [ ] **Step 4: Implement atomic schema v2 migration**

Set `schemaVersion = 2`. Migrate inside one SQLite transaction: add `source_kind`, `connection_state`, `filename_normalized`, `relative_directory`, and `last_edit_at`; backfill every row before adding indexes. Normalize with Foundation NFC plus locale-independent lowercasing at write time. Add an internal `migrationHook` test seam that defaults to `{}` and runs before the version record is updated.

```sql
ALTER TABLE library ADD COLUMN source_kind TEXT NOT NULL DEFAULT 'externalFolder';
ALTER TABLE library ADD COLUMN connection_state TEXT NOT NULL DEFAULT 'ready';
ALTER TABLE library ADD COLUMN scan_state TEXT NOT NULL DEFAULT 'idle';
ALTER TABLE photo ADD COLUMN filename_normalized TEXT NOT NULL DEFAULT '';
ALTER TABLE photo ADD COLUMN relative_directory TEXT NOT NULL DEFAULT '';
ALTER TABLE photo ADD COLUMN last_edit_at REAL;
CREATE INDEX photo_all_capture_desc ON photo (capture_date DESC, photo_id);
CREATE INDEX photo_library_capture_desc ON photo (library_id, capture_date DESC, photo_id);
CREATE INDEX photo_library_directory_capture_desc
    ON photo (library_id, relative_directory, capture_date DESC, photo_id);
CREATE INDEX photo_filename_normalized ON photo (filename_normalized, photo_id);
CREATE INDEX photo_last_edit_desc ON photo (last_edit_at DESC, photo_id)
    WHERE last_edit_at IS NOT NULL;
```

- [ ] **Step 5: Write failing query tests**

Cover all/source/folder/app-storage/recent scopes, four sorts, NFC filename search, two pages with tied sort values, and a deleted row between pages. The key assertion is identity completeness, not only count:

```swift
func testKeysetPagingAcrossSourcesHasNoDuplicatesOrGaps() throws {
    let expected = try seedThreeLibraries(photoCountPerLibrary: 137)
    let query = LibraryQuery(scope: .all, sort: .captureDateDescending)
    var cursor: PhotoPageCursor?
    var actual: [PhotoID] = []
    repeat {
        let page = try store.page(matching: query, after: cursor, limit: 100)
        actual.append(contentsOf: page.photos.map(\.id))
        cursor = page.nextCursor
    } while cursor != nil
    XCTAssertEqual(actual, expected)
    XCTAssertEqual(Set(actual).count, actual.count)
}
```

- [ ] **Step 6: Implement bound SQL query generation**

Implement `page(matching:after:limit:)` with parameter binding only. Reject limits outside `1...200`. Filename search is normalized substring matching; escape `%`, `_` and the SQL escape character before binding the `LIKE` pattern. Folder scope matches the exact directory plus descendants using escaped relative path semantics; an empty path means the source root. `.recentlyEdited` forces `last_edit_at DESC, photo_id`; other scopes honour `PhotoSort`. NULL capture dates sort after dated photos in both directions. Select `limit + 1` rows to determine `nextCursor`. Implement `childDirectories(libraryID:parent:)` as a bound immediate-child query so the sidebar expands lazily rather than loading every directory. Implement `setEditState` so neutral saves clear both `has_edits` and `last_edit_at`, while successful non-neutral saves store the sidecar `modifiedAt`.

- [ ] **Step 7: Run focused and full core tests**

Run:

```bash
swift test --filter 'PhotoIndex(Migration|Query)Tests'
swift test --filter PhotoLibraryCoreTests
swift build -Xswiftc -strict-concurrency=complete
```

Expected: all selected tests pass; strict build exits 0.

- [ ] **Step 8: Commit Task 1**

```bash
git add Sources/PhotoLibraryCore/Model/LibraryQuery.swift Sources/PhotoLibraryCore/Model/PhotoAsset.swift Sources/PhotoLibraryCore/Index/PhotoIndexStore.swift Tests/PhotoLibraryCoreTests/PhotoIndexMigrationTests.swift Tests/PhotoLibraryCoreTests/PhotoIndexQueryTests.swift
git commit -m "feat: add paged multi-source library index"
```

### Task 2: Model source state, stable identity and overlap rejection

**Files:**
- Create: `Sources/PhotoLibraryCore/Scanning/LibrarySourceIdentity.swift`
- Modify: `Sources/PhotoLibraryCore/Model/LibraryFolder.swift`
- Modify: `Sources/PhotoLibraryCore/Access/BookmarkStore.swift`
- Modify: `Sources/PhotoLibraryCore/Service/PhotoLibraryService.swift`
- Test: `Tests/PhotoLibraryCoreTests/LibrarySourceIdentityTests.swift`
- Test: `Tests/PhotoLibraryCoreTests/LibrarySourceLifecycleTests.swift`

**Interfaces:**
- Consumes: Task 1 schema v2 and existing bookmark／manifest identity.
- Produces: `LibrarySourceKind`, `LibraryConnectionState`, `LibrarySourceIdentity`, `SourceRelationship`, `PhotoLibraryService.addLibrary(at:displayName:sourceKind:)`, and persisted source state.

- [ ] **Step 1: Write failing identity and lifecycle tests**

Test manifest identity wins, an exact existing source focuses instead of duplicates, resolvable parent/child overlap throws, same display name on different volumes remains distinct, stale bookmark becomes `needsAuthorization`, and removing a source never invokes a source-file remover.

```swift
func testParentChildSourceOverlapIsRejectedWithoutWriting() async throws {
    let parent = try makeDirectory("Photos")
    let child = try makeDirectory("Photos/Trip")
    _ = try await service.addLibrary(at: parent, sourceKind: .externalFolder)

    await XCTAssertThrowsErrorAsync(
        try await service.addLibrary(at: child, sourceKind: .externalFolder)
    ) { error in
        XCTAssertEqual(error as? LibraryError, .overlappingSource)
    }
    XCTAssertEqual(await service.knownLibraries().count, 1)
}
```

- [ ] **Step 2: Run tests and confirm RED**

```bash
swift test --filter 'LibrarySource(Identity|Lifecycle)Tests'
```

Expected: compile failures for source kind, connection state and overlap error.

- [ ] **Step 3: Implement public source state**

Add the exact enums from the approved spec. Replace stored `isOnline`／`isWritable` with `connectionState`, while retaining computed compatibility accessors so existing Mac call sites compile unchanged.

```swift
public enum LibrarySourceKind: String, Codable, Sendable {
    case externalFolder, filesProvider, appStorage
}

public enum LibraryConnectionState: String, Codable, Sendable {
    case ready, readOnly, offline, needsAuthorization
}

public enum LibraryScanState: String, Codable, Sendable {
    case idle, queued, scanning, partialFailure
}
```

- [ ] **Step 4: Implement source identity and overlap decisions**

`LibrarySourceIdentity` contains optional manifest `LibraryID`, bookmark resource identifier bytes, volume identifier string, and a bounded root fingerprint. Implement `relationship(to:) -> SourceRelationship` returning `.same`, `.ancestor`, `.descendant`, `.distinct`, or `.ambiguous`. Only `.same` reuses and `.ancestor/.descendant` reject; `.ambiguous` requires explicit user confirmation and never auto-relinks.

- [ ] **Step 5: Persist and restore the new state**

Extend `StoredBookmark` with backward-compatible optional fields. Existing records decode as `.externalFolder`; restoration maps bookmark resolution failure to `.needsAuthorization`, a missing volume to `.offline`, and writable status to `.ready`／`.readOnly`. Keep `scanState` independent: persist only `.idle` or `.partialFailure`, and normalize interrupted `.queued`／`.scanning` to `.idle` at launch. Do not store a runtime root URL as identity.

- [ ] **Step 6: Run regressions and commit**

```bash
swift test --filter 'LibrarySource(Identity|Lifecycle)Tests'
swift test --filter 'FileBookmarkStoreTests|RelinkResolverTests|LibraryLifecycleTests'
git diff --check
git add Sources/PhotoLibraryCore/Scanning/LibrarySourceIdentity.swift Sources/PhotoLibraryCore/Model/LibraryFolder.swift Sources/PhotoLibraryCore/Access/BookmarkStore.swift Sources/PhotoLibraryCore/Service/PhotoLibraryService.swift Tests/PhotoLibraryCoreTests/LibrarySourceIdentityTests.swift Tests/PhotoLibraryCoreTests/LibrarySourceLifecycleTests.swift
git commit -m "feat: persist multi-source identity and availability"
```

Expected: all named tests pass; no existing bookmark fixture is rejected.

### Task 3: Schedule bounded scans across multiple sources

**Files:**
- Create: `Sources/PhotoLibraryCore/Service/MultiSourceScanCoordinator.swift`
- Modify: `Sources/PhotoLibraryCore/Service/PhotoLibraryService.swift`
- Test: `Tests/PhotoLibraryCoreTests/MultiSourceScanCoordinatorTests.swift`
- Test: `Tests/LumaHarborIntegrationTests/MultiSourceBoundedScanTests.swift`

**Interfaces:**
- Consumes: existing `LibraryScanEvent`, generation checks and Task 2 source state.
- Produces: `MultiSourceScanCoordinator.enqueue(libraryID:priority:operation:)`, `cancel(libraryID:)`, and `PhotoLibraryService.scanLibraries(_:selectedLibraryID:)`.

- [ ] **Step 1: Write failing coordinator tests**

Use gated operations to prove two distinct sources run, the third waits, a duplicate enqueue replaces the queued generation, selected-source priority changes queue order, and cancel never leaks a slot.

```swift
func testOnlyTwoSourcesRunAndThirdWaits() async throws {
    let tracker = ScanTracker()
    await coordinator.enqueue(libraryID: ids[0], priority: .normal) { await tracker.run(ids[0]) }
    await coordinator.enqueue(libraryID: ids[1], priority: .normal) { await tracker.run(ids[1]) }
    await coordinator.enqueue(libraryID: ids[2], priority: .normal) { await tracker.run(ids[2]) }
    await tracker.waitForStartedCount(2)
    XCTAssertEqual(await tracker.maximumConcurrentCount, 2)
    XCTAssertFalse(await tracker.startedIDs.contains(ids[2]))
    await tracker.release(ids[0])
    await tracker.waitUntilStarted(ids[2])
}
```

- [ ] **Step 2: Run tests and confirm RED**

```bash
swift test --filter MultiSourceScanCoordinatorTests
```

- [ ] **Step 3: Implement the actor scheduler**

Use an actor with exactly two active task slots and a FIFO queue carrying selected-source priority. One `LibraryID` may be active or queued once. Cancellation removes queued work or cancels active work; task completion re-enters the actor and starts the next item. Do not use polling, semaphores, detached tasks or unbounded continuations.

- [ ] **Step 4: Integrate without weakening the scan pipeline**

`PhotoLibraryService.scanLibraries` enqueues existing per-library scan operations. Preserve the current scan-generation validation and acknowledged channels. A complete scan may prune and update `lastScanAt`; cancellation, offline, authorization failure or partial source failure must not prune.

- [ ] **Step 5: Add the 3×10,000 integration test**

Use three instrumented cursors and a deliberately slow consumer. Assert every expected `(LibraryID, relativePath)` arrives exactly once, global active scans never exceed two, and each underlying pipeline reports retained batch high-water `<= 2`.

- [ ] **Step 6: Run and commit**

```bash
swift test --filter 'MultiSource(ScanCoordinator|BoundedScan)Tests'
swift test --filter 'BoundedFolderScanTests|ScanCancellationTests'
git add Sources/PhotoLibraryCore/Service/MultiSourceScanCoordinator.swift Sources/PhotoLibraryCore/Service/PhotoLibraryService.swift Tests/PhotoLibraryCoreTests/MultiSourceScanCoordinatorTests.swift Tests/LumaHarborIntegrationTests/MultiSourceBoundedScanTests.swift
git commit -m "feat: coordinate bounded scans across library sources"
```

### Task 4: Project committed App copies into the library and open indexed documents

**Files:**
- Modify: `Sources/PhotoLibraryCore/Documents/PhotoDocumentStore.swift`
- Modify: `Sources/PhotoLibraryCore/Documents/PhotoDocument.swift`
- Modify: `Sources/PhotoLibraryCore/Model/PhotoID.swift`
- Modify: `Sources/PhotoLibraryCore/Service/PhotoLibraryService.swift`
- Modify: `Sources/EditorCore/PhotoDocumentEditor.swift`
- Test: `Tests/PhotoLibraryCoreTests/PhotoDocumentStoreListingTests.swift`
- Test: `Tests/EditorCoreTests/PhotoDocumentEditorLibraryOpenTests.swift`

**Interfaces:**
- Consumes: committed `PhotoDocument` records and Task 1 `.appStorage` scope.
- Produces: `PhotoDocumentStore.committedDocuments()`, `PhotoLibraryService.refreshAppStorageProjection(from:)`, `PhotoDocumentEditor.openLibraryAsset(_:)`, and `LibraryOpenAsset`.

- [ ] **Step 1: Write failing document-listing tests**

Create one committed App copy, one committed in-place record, one pending record and one corrupt record. `committedDocuments()` must return the two committed readable records in stable UUID order, report corrupt records separately, and never promote or delete pending data.

- [ ] **Step 2: Define the editor handoff value**

```swift
public enum LibraryOpenAsset: Sendable, Equatable {
    case external(url: URL, sourceKind: LibrarySourceKind)
    case appCopy(documentID: UUID)
}
```

The external URL is runtime-only and must not be logged. `.appCopy` opens the existing committed record; it must not call `importCopy` again.

- [ ] **Step 3: Implement committed listing and App-storage projection**

Enumerate only record files under the store's records directory while holding the existing root coordination rules. Decode records, include only effective `.committed`, verify their working file exists, and return per-record failures. Add `LibraryID.appStorage` in `PhotoID.swift` using the fixed UUID `6C554D41-4841-5242-4F52-000000000001`; project valid App copies into that synthetic source and Task 1 index. The projection is local and rebuildable.

- [ ] **Step 4: Write and run failing editor transition tests**

```swift
func testOpeningIndexedAppCopyDoesNotImportAgain() async throws {
    let harness = try EditorHarness.withCommittedAppCopy()
    harness.editor.openLibraryAsset(.appCopy(documentID: harness.document.id))
    await harness.waitUntilIdle()
    XCTAssertEqual(harness.store.importCopyCallCount, 0)
    XCTAssertEqual(harness.editor.document?.id, harness.document.id)
}

func testOfflineExternalAssetLeavesCurrentDocumentUntouched() async throws {
    let harness = try EditorHarness.withOpenDocument()
    harness.editor.openLibraryAsset(.external(url: harness.missingURL, sourceKind: .externalFolder))
    await harness.waitUntilIdle()
    XCTAssertEqual(harness.editor.document?.id, harness.originalDocument.id)
    XCTAssertEqual(harness.editor.alert?.nextStep, L10n.t("Reconnect the source, then try again."))
}
```

- [ ] **Step 5: Implement the two-phase library open**

Reuse `PhotoDocumentEditor`'s existing cancellation generation, scope acquisition, flush-before-switch, decode, rollback and alert machinery. External indexed assets bypass the import-choice dialog and use `.inPlace`; App copies load their committed record. No new document becomes visible until validation succeeds.

- [ ] **Step 6: Run and commit**

```bash
swift test --filter 'PhotoDocumentStoreListingTests|PhotoDocumentEditorLibraryOpenTests'
swift test --filter 'PhotoDocumentStoreTests|PhotoDocumentEditorTests'
git add Sources/PhotoLibraryCore/Documents/PhotoDocumentStore.swift Sources/PhotoLibraryCore/Documents/PhotoDocument.swift Sources/PhotoLibraryCore/Model/PhotoID.swift Sources/PhotoLibraryCore/Service/PhotoLibraryService.swift Sources/EditorCore/PhotoDocumentEditor.swift Tests/PhotoLibraryCoreTests/PhotoDocumentStoreListingTests.swift Tests/EditorCoreTests/PhotoDocumentEditorLibraryOpenTests.swift
git commit -m "feat: open indexed external and iPad library photos"
```

### Task 5: Build the testable browser state machine in `EditorCore`

**Files:**
- Create: `Sources/EditorCore/LibraryBrowserDependencies.swift`
- Create: `Sources/EditorCore/LibraryBrowserSession.swift`
- Test: `Tests/EditorCoreTests/LibraryBrowserSessionTests.swift`

**Interfaces:**
- Consumes: Task 1 pages, Task 2 source states, Task 3 events and Task 4 `LibraryOpenAsset`.
- Produces: observable `LibraryBrowserSession`, `LibrarySelection`, `LibraryBrowserLoadState`, `GridRestorationState`, `select(_:)`, `loadNextPage()`, and `openAsset(for:)`.

- [ ] **Step 1: Define injectable dependencies and failing tests**

```swift
public struct LibraryBrowserDependencies: Sendable {
    public var restoreSources: @Sendable () async throws -> [LibraryFolder]
    public var fetchPage: @Sendable (LibraryQuery, PhotoPageCursor?, Int) async throws -> PhotoPage
    public var childDirectories: @Sendable (LibraryID, String) async throws -> [LibraryDirectoryNode]
    public var addSource: @Sendable (URL, LibrarySourceKind) async throws -> LibraryFolder
    public var relinkSource: @Sendable (LibraryID, URL) async throws -> LibraryFolder
    public var runScan: @Sendable (
        LibraryID,
        @escaping @Sendable (LibraryScanEvent) async -> Void
    ) async -> Void
    public var removeSource: @Sendable (LibraryID) async throws -> Void
    public var resolveOpenAsset: @Sendable (PhotoID) async throws -> LibraryOpenAsset

    public init(
        restoreSources: @escaping @Sendable () async throws -> [LibraryFolder],
        fetchPage: @escaping @Sendable (LibraryQuery, PhotoPageCursor?, Int) async throws -> PhotoPage,
        childDirectories: @escaping @Sendable (LibraryID, String) async throws -> [LibraryDirectoryNode],
        addSource: @escaping @Sendable (URL, LibrarySourceKind) async throws -> LibraryFolder,
        relinkSource: @escaping @Sendable (LibraryID, URL) async throws -> LibraryFolder,
        runScan: @escaping @Sendable (LibraryID, @escaping @Sendable (LibraryScanEvent) async -> Void) async -> Void,
        removeSource: @escaping @Sendable (LibraryID) async throws -> Void,
        resolveOpenAsset: @escaping @Sendable (PhotoID) async throws -> LibraryOpenAsset
    ) {
        self.restoreSources = restoreSources
        self.fetchPage = fetchPage
        self.childDirectories = childDirectories
        self.addSource = addSource
        self.relinkSource = relinkSource
        self.runScan = runScan
        self.removeSource = removeSource
        self.resolveOpenAsset = resolveOpenAsset
    }
}

public enum LibrarySelection: Sendable, Equatable {
    case smart(LibraryScope)
    case source(LibraryID)
    case folder(libraryID: LibraryID, relativePath: String)
}

public enum LibraryBrowserLoadState: Sendable, Equatable {
    case idle, loadingFirstPage, loadingNextPage, loaded, failed(EditorAlert)
}

public struct GridRestorationState: Sendable, Equatable {
    public var query: LibraryQuery
    public var anchorPhotoID: PhotoID?
}
```

Write tests for startup restoration, page append, source switch during an outstanding request, search debounce cancellation, duplicate page rejection, offline open gate, per-source progress, error recovery and `PhotoID` scroll anchor restoration.

- [ ] **Step 2: Run tests and confirm RED**

```bash
swift test --filter LibraryBrowserSessionTests
```

- [ ] **Step 3: Implement query and generation state**

`LibraryBrowserSession` is `@MainActor final class ObservableObject`. Publish sources, selection, photos, next cursor, per-source progress, alert, `LibraryBrowserLoadState` and restoration anchor. Increment `queryGeneration` for scope/search/sort changes; capture it in every task and discard late results. Keep at most the current page window plus two prefetched pages; do not accumulate every row indefinitely. Production `runScan` must iterate the existing acknowledged `LibraryScanSequence` and `await` the handler for each event; do not bridge it through a buffering `AsyncStream`.

- [ ] **Step 4: Implement stable restoration and commands**

Store `GridRestorationState(query:anchorPhotoID:)` in memory when entering editor. Restore by querying until the anchor is found or the result ends, capped at 20 pages; if absent, show page one without error. Reject editor open for `.offline`／`.needsAuthorization`; read-only sources may decode but editor receives read-only mode.

- [ ] **Step 5: Run strict tests and commit**

```bash
swift test --filter LibraryBrowserSessionTests
swift test --filter EditorCoreTests
swift build -Xswiftc -strict-concurrency=complete
git add Sources/EditorCore/LibraryBrowserDependencies.swift Sources/EditorCore/LibraryBrowserSession.swift Tests/EditorCoreTests/LibraryBrowserSessionTests.swift
git commit -m "feat: add testable multi-source library browser session"
```

### Task 6: Compose iPad services and adaptive library navigation

**Files:**
- Create: `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadAppServices.swift`
- Create: `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadLibraryModel.swift`
- Create: `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadLibraryView.swift`
- Create: `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadLibrarySidebar.swift`
- Modify: `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/LumaHarborPadApp.swift`
- Modify: `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadRootView.swift`
- Test: `Tests/EditorCoreTests/PadLibraryCompositionContractTests.swift`

**Interfaces:**
- Consumes: Task 5 `LibraryBrowserSession` and existing `PadEditorModel`.
- Produces: one app-lifetime `PadAppServices`, `typealias PadLibraryModel = LibraryBrowserSession`, and library/editor route state.

- [ ] **Step 1: Write composition contract tests**

Use source parsing tests to assert `PadLibraryModel.swift` contains only the typealias/import contract and no second state machine. Add a root-package compile contract proving `LibraryBrowserDependencies.production(...)` can be constructed from one `PhotoLibraryService` and one `PhotoDocumentStore`.

- [ ] **Step 2: Create the production composition root**

`PadAppServices` owns a single application-support location, `PhotoLibraryService`, 2 GiB `DiskCache`, `ThumbnailProvider`, `PhotoDocumentStore`, `PadLibraryModel` and `PadEditorModel`. Construct each once in `LumaHarborPadApp.init`; do not create services from a SwiftUI `body`.

```swift
typealias PadLibraryModel = LibraryBrowserSession

@main
struct LumaHarborPadApp: App {
    @StateObject private var library: PadLibraryModel
    @StateObject private var editor: PadEditorModel
    // init builds both from one PadAppServices instance.
}
```

- [ ] **Step 3: Build the adaptive route container**

When no document is open, `PadRootView` shows `PadLibraryView`; when the editor owns a document it shows existing `PadEditorView`. regular width uses a visible sidebar; compact width presents the same `PadLibrarySidebar` from a toolbar button. Existing single-file `Open RAW…` remains available as a secondary action.

- [ ] **Step 4: Build and commit**

```bash
swift test --filter PadLibraryCompositionContractTests
(cd Apps/LumaHarborPad.swiftpm && xcodebuild -scheme LumaHarborPad -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build)
git add Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadAppServices.swift Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadLibraryModel.swift Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadLibraryView.swift Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadLibrarySidebar.swift Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/LumaHarborPadApp.swift Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadRootView.swift Tests/EditorCoreTests/PadLibraryCompositionContractTests.swift
git commit -m "feat: add adaptive iPad library navigation"
```

### Task 7: Add the paged thumbnail grid, search, sorting and editor return

**Files:**
- Create: `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadLibraryGrid.swift`
- Create: `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadThumbnailCell.swift`
- Create: `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadLibrarySettingsView.swift`
- Modify: `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadLibraryView.swift`
- Modify: `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadRootView.swift`
- Modify: `Sources/EditorCore/LibraryBrowserSession.swift`
- Modify: `Sources/Localization/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/Localization/Resources/zh-Hant.lproj/Localizable.strings`
- Test: `Tests/EditorCoreTests/LibraryBrowserGridFlowTests.swift`
- Test: `Tests/AdjustmentUITests/PadLibraryAccessibilityContractTests.swift`

**Interfaces:**
- Consumes: Task 5 page window and Task 6 navigation.
- Produces: lazy paged grid, thumbnail task cancellation, filename search, four sorts, grid-size preference, bounded cache-budget setting, accessibility labels and editor return restoration.

- [ ] **Step 1: Write failing browser flow tests**

Test that a near-end sentinel loads exactly one next page, rapid scope/search/sort changes show only the final generation, editor return restores by `PhotoID`, a missing anchor falls back to page one, and offline selection returns a localised actionable alert instead of opening.

- [ ] **Step 2: Implement the grid and thumbnail cell**

Use `LazyVGrid` and stable `PhotoID`. Each cell starts a cancellable thumbnail task only while visible, shows neutral placeholder/error/offline/edited states, and pins cache work only for the visible lifetime. Trigger prefetch when the user reaches the last 20 visible items; `LibraryBrowserSession` deduplicates concurrent page requests.

- [ ] **Step 3: Implement toolbar query controls**

Add filename search with 250 ms debounce, four sorts except `.recentlyEdited` which fixes modified-descending, and a persisted column/thumbnail-size preference. Query changes clear displayed pages, increment generation and request page one.

- [ ] **Step 4: Add accessibility and localisation contracts**

Every cell accessibility label includes filename, capture date when available, source display name, connection/error status and edited state. Add both English and Traditional Chinese translations for every new visible string. Ensure toolbar and cells expose 44×44 pt minimum hit regions and do not use colour as the only signal.

- [ ] **Step 5: Add the cache-budget setting**

Create `PadLibrarySettingsView` with discrete choices 512 MiB, 1 GiB, 2 GiB, 5 GiB and 10 GiB. Persist the selected byte count in `UserDefaults`, clamp decoded values to the approved range, and call the existing cache `setByteBudget` path immediately. The default when absent or invalid is exactly 2 GiB; this setting must not change the Mac `CacheBudget` constants.

- [ ] **Step 6: Run and commit**

```bash
swift test --filter 'LibraryBrowserGridFlowTests|PadLibraryAccessibilityContractTests'
(cd Apps/LumaHarborPad.swiftpm && xcodebuild -scheme LumaHarborPad -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build)
git add Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadLibraryGrid.swift Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadThumbnailCell.swift Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadLibrarySettingsView.swift Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadLibraryView.swift Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadRootView.swift Sources/EditorCore/LibraryBrowserSession.swift Sources/Localization/Resources/en.lproj/Localizable.strings Sources/Localization/Resources/zh-Hant.lproj/Localizable.strings Tests/EditorCoreTests/LibraryBrowserGridFlowTests.swift Tests/AdjustmentUITests/PadLibraryAccessibilityContractTests.swift
git commit -m "feat: browse paged RAW thumbnails on iPad"
```

### Task 8: Harden source operations, privacy and Mac regressions

**Files:**
- Modify: `Sources/PhotoLibraryCore/Service/PhotoLibraryService.swift`
- Modify: `Sources/EditorCore/LibraryBrowserSession.swift`
- Modify: `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadLibrarySidebar.swift`
- Test: `Tests/PhotoLibraryCoreTests/LibraryRemovalSafetyTests.swift`
- Test: `Tests/LumaHarborIntegrationTests/MultiSourceFailureRecoveryTests.swift`
- Test: `Tests/LumaHarborAppTests/LibraryViewModelTransitionTests.swift`

**Interfaces:**
- Consumes: Tasks 1–7.
- Produces: complete remove/relink/rescan safety, provider timeout, late-event rejection and unchanged Mac behavior.

- [ ] **Step 1: Write destructive-safety and failure tests**

Use a recording file manager to prove remove source touches only bookmark, index and cache roots. Test scan-time drive removal, 30-second provider request timeout via injected clock, retry generation, corrupt RAW continuation, no prune after cancellation／offline／partial failure, and prune after complete success.

- [ ] **Step 2: Implement actionable source commands**

Sidebar commands call browser dependencies, never direct filesystem APIs. Remove source requires a confirmation whose text states RAW and sidecars remain. Reauthorise/relink verifies Task 2 identity. Rescan updates progress per source. Timeout creates per-file failure and continues; it never retries automatically forever.

- [ ] **Step 3: Run the existing Mac behavior gates**

```bash
swift test --filter 'LibraryRemovalSafetyTests|MultiSourceFailureRecoveryTests'
swift test --filter 'LibraryViewModelTransitionTests|LibraryLifecycleTests|ThumbnailProviderTests'
swift test
swift build -Xswiftc -strict-concurrency=complete
```

Expected: all tests pass; no Mac selection, autosave, cache or scan test changes expected output.

- [ ] **Step 4: Commit**

```bash
git add Sources/PhotoLibraryCore/Service/PhotoLibraryService.swift Sources/EditorCore/LibraryBrowserSession.swift Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadLibrarySidebar.swift Tests/PhotoLibraryCoreTests/LibraryRemovalSafetyTests.swift Tests/LumaHarborIntegrationTests/MultiSourceFailureRecoveryTests.swift Tests/LumaHarborAppTests/LibraryViewModelTransitionTests.swift
git commit -m "fix: harden multi-source library lifecycle"
```

### Task 9: Add automated acceptance evidence and real-device checklist

**Files:**
- Create: `Scripts/run-ipad-library-acceptance.zsh`
- Create: `docs/testing/reports/2026-08-26-ipad-multi-source-library.md`
- Modify: `README.md`
- Test: self-test mode inside `Scripts/run-ipad-library-acceptance.zsh`

**Interfaces:**
- Consumes: all previous tasks and the existing strengthened iPad vertical-slice runner evidence protocol.
- Produces: `.build/ipad-library/<timestamp-pid-random>/summary.md`, redacted logs, runner self-tests and a real-device report.

- [ ] **Step 1: Write runner self-tests before the production flow**

Add explicit `__selftest` argv mode. Cover successful five-step simulation, command failure, grep exit 2, redaction failure, permanent publish `mv` failure, TERM in every publish checkpoint, concurrent runs, forged environment markers, child cleanup and privacy paths containing spaces／Unicode. Every self-test summary begins with `Run mode: SELFTEST`.

- [ ] **Step 2: Run self-tests and confirm RED**

```bash
Scripts/run-ipad-library-acceptance.zsh __selftest
```

Expected: non-zero until the production runner and evidence protocol are connected.

- [ ] **Step 3: Implement the fail-fast acceptance flow**

Run in order:

```zsh
swift build -Xswiftc -strict-concurrency=complete
swift test
(cd Apps/LumaHarborPad.swiftpm && xcodebuild -scheme LumaHarborPad -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build)
swift test --filter MultiSourceBoundedScanTests
Scripts/run-mvp-acceptance.zsh --preflight-only
Scripts/run-mvp-acceptance.zsh
Scripts/run-ipad-vertical-slice-acceptance.zsh
```

Reuse or extract the existing verifiable evidence protocol; do not weaken it or create an environment-variable override channel. Summary records exit code, PASS／FAIL／NOT RUN, actual test count, repo fingerprint and privacy result. Only grep exit 1 means clean.

- [ ] **Step 4: Prove stability**

Run:

```bash
zsh -n Scripts/run-ipad-library-acceptance.zsh
for i in {1..10}; do Scripts/run-ipad-library-acceptance.zsh __selftest || exit $?; done
pgrep -fl 'run-ipad-library-acceptance|xcodebuild|swift-frontend|xctest'
```

Expected: ten exit-0 runs and no process belonging to the runner after completion.

- [ ] **Step 5: Run automated fixture acceptance**

With private RAW, APFS and exFAT fixture directories exported, run `Scripts/run-ipad-library-acceptance.zsh`. Expected summary: every automated step, repo state and privacy scan PASS. If fixtures or an external volume are unavailable, record `NOT RUN`; do not fabricate a PASS.

- [ ] **Step 6: Execute the real M1+ iPad checklist**

Record each item separately: APFS add/scan/relaunch, exFAT add/unplug/offline/relink, one Files provider reauthorisation, three-source aggregate search/sort/restoration, and real Sony ARW edit/autosave/reopen/checksum. Use the user's Development Team selected in Xcode; never guess or commit a team identifier.

- [ ] **Step 7: Update report, README and commit**

```bash
git add Scripts/run-ipad-library-acceptance.zsh docs/testing/reports/2026-08-26-ipad-multi-source-library.md README.md
git commit -m "test: verify iPad multi-source RAW library"
git diff --check HEAD~1 HEAD
git status --short --branch
```

Expected: clean worktree; report clearly separates automated PASS from every real-device PASS or NOT RUN.

## Spec Coverage Map

| Approved design area | Implementation tasks |
|---|---|
| Multi-source SQLite, paging, folder tree, search, sort, recent edits | Task 1 |
| Source kind, connection／scan state, bookmark identity, overlap and relink | Task 2 |
| Two-source concurrency, bounded backpressure, cancellation and prune rules | Tasks 3 and 8 |
| iPad App-copy projection and indexed editor opening | Task 4 |
| Query generation, page window, source progress and scroll restoration | Task 5 |
| App-lifetime composition, adaptive sidebar and source picker | Task 6 |
| Lazy thumbnail grid, cache budget, localisation and accessibility | Task 7 |
| Offline／timeout／remove-source safety and Mac regression | Task 8 |
| Automated evidence, privacy, APFS／exFAT／Files provider and Sony ARW gates | Task 9 |
| Explicitly deferred ratings, albums, batches, non-RAW assets and advanced edits | Global Constraints and Final Review Gate |

## Final Review Gate

After Task 9:

1. Compare every section of `docs/superpowers/specs/2026-08-26-ipad-multi-source-photo-library-design.md` to implemented code and tests.
2. Run `rg -n 'TBD|TODO|FIXME|fatalError|try!|force unwrap'` across changed production files and resolve every hit or document why it is safe.
3. Run the full automated acceptance runner with real fixtures.
4. Perform an independent pre-landing review focused on SQLite migration rollback, keyset cursor correctness, source identity, scan cancellation/prune rules, editor two-phase switching, privacy and signal-safe evidence publication.
5. Do not merge or claim completion while any required real-device item is `NOT RUN`.
