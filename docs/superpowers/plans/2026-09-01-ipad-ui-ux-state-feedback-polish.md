# iPad UI/UX State Feedback Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the iPad app's source, loading, reauthorisation, remove-source, RAW open, and save-state feedback explicit enough that a tester can tell what the app is doing and whether RAW originals remain safe.

**Architecture:** Keep `LibraryBrowserSession` as the source of truth for library/query/source lifecycle state, and keep SwiftUI views as thin renderers of that state. Add only small UI-facing state helpers where the app package cannot be directly unit-tested; lock those with source-parsing contract tests and session-level behavior tests.

**Tech Stack:** Swift 5.9 package, SwiftUI iPad app target, XCTest, existing `EditorCore`, `PhotoLibraryCore`, and `Localization` modules.

## Global Constraints

- User-visible replies, docs, and coordination updates remain Traditional Chinese where they face the user; product UI strings continue to use English-string keys through `L10n.t`.
- Do not modify RAW originals. Removal, reconnect, scan, open, and save-failure copy must not imply RAW files are moved, overwritten, or deleted.
- Do not expose private absolute paths, mount paths, Apple Development Team IDs, provider internals, credentials, or fixture paths in UI, docs, tests, or reports.
- Keep `Read-only`, `Offline`, and `Needs Access` distinct in UI and tests.
- Keep `PASS`, `FAIL`, `SKIPPED`, and `NOT RUN` distinct in verification records.
- Do not add Before/After, reset, batch apply, JPEG/HEIF export, TestFlight/App Store distribution, or Mac UI rewrites in this plan.
- Preserve unrelated dirty files and stage exact paths only.

---

## File Structure

- Modify `Sources/EditorCore/LibraryBrowserSession.swift`
  - Add a small UI-facing query/source operation state if existing `loadState` and `sourceProgress` cannot express the required copy without view-local guessing.
  - Keep query generation and paging semantics unchanged.
- Modify `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadLibraryView.swift`
  - Render global add/scan overlays with precise title and safety message.
- Modify `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadLibrarySidebar.swift`
  - Render per-source `Scanning`, `Partial issue`, `Read-only`, `Offline`, `Needs Access`, reconnect, and remove-source copy.
- Modify `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadLibraryGrid.swift`
  - Split empty/offline/needs-access/no-results/no-supported-RAW states where the current session state can identify them.
- Modify `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorView.swift`
  - Rename save failure UI from `Not saved` to `Save failed` and add RAW-safety/next-step hint where feasible.
- Modify `Sources/Localization/Resources/en.lproj/Localizable.strings`
  - Add every new English key.
- Modify `Sources/Localization/Resources/zh-Hant.lproj/Localizable.strings`
  - Add every matching Traditional Chinese translation.
- Modify `Tests/EditorCoreTests/LibraryBrowserSessionTests.swift`
  - Behavior tests for operation states and source progress semantics.
- Modify `Tests/EditorCoreTests/PadLibraryCompositionContractTests.swift`
  - Source-parse tests for SwiftUI app package state/copy contracts.
- Modify `Tests/AdjustmentUITests/PadLibraryAccessibilityContractTests.swift`
  - Source-parse tests for visible text and non-color-only feedback.
- Modify `Tests/EditorCoreTests/PhotoDocumentEditorLibraryOpenTests.swift` or `Tests/EditorCoreTests/EditorSessionDocumentPersistenceTests.swift`
  - Save-state behavior tests if a behavior change is needed.
- Modify `docs/coordination/CURRENT.md`
  - Record implementation-plan commit, current ownership, and next action after the plan is committed.

---

### Task 1: Library operation state contract

**Files:**
- Modify: `Sources/EditorCore/LibraryBrowserSession.swift`
- Test: `Tests/EditorCoreTests/LibraryBrowserSessionTests.swift`

**Interfaces:**
- Consumes: existing `LibraryBrowserSession.addSource(at:sourceKind:)`, `relinkSource(_:to:)`, `removeSource(_:)`, `scanSource(_:)`, `loadState`, and `sourceProgress`.
- Produces: either existing state proven sufficient, or a new published property:

```swift
public enum LibraryBrowserOperationState: Sendable, Equatable {
    case idle
    case addingSource
    case scanningSource(LibraryID)
    case reconnectingSource(LibraryID)
    case removingSource(LibraryID)
}
```

and:

```swift
@Published public private(set) var operationState: LibraryBrowserOperationState = .idle
```

- Later tasks may render `operationState` but must not duplicate the lifecycle state machine in SwiftUI view-local flags except for picker presentation.

- [ ] **Step 1: Write failing tests for operation states**

Add tests that intentionally fail before the property exists:

```swift
@MainActor
func testAddSourcePublishesAddingSourceWhileDependencyIsSuspended() async throws {
    let environment = FakeLibraryEnvironment()
    let source = makeFolder(name: "Camera")
    await environment.setAddSourceResult(.success(source))
    await environment.setAddSourceGated(true)
    let session = LibraryBrowserSession(dependencies: makeDependencies(environment))

    Task { await session.addSource(at: source.rootURL, sourceKind: .externalFolder) }

    try await waitUntil { session.operationState == .addingSource }
    await environment.openAddSourceGate()
    try await waitUntil { session.operationState == .idle }
    XCTAssertEqual(session.sources.map(\.id), [source.id])
}

@MainActor
func testRelinkAndRemovePublishDistinctOperationStates() async throws {
    let environment = FakeLibraryEnvironment()
    let source = makeFolder(connectionState: .needsAuthorization)
    await environment.setSourcesResult(.success([source]))
    await environment.setRelinkResult(.success(makeFolder(id: source.id, connectionState: .ready)))
    await environment.setRelinkGated(true)
    await environment.setRemoveGated(true)
    let session = LibraryBrowserSession(dependencies: makeDependencies(environment))
    session.start()
    try await waitUntil { session.sources.count == 1 }

    Task { await session.relinkSource(source.id, to: source.rootURL) }
    try await waitUntil { session.operationState == .reconnectingSource(source.id) }
    await environment.openRelinkGate()
    try await waitUntil { session.operationState == .idle }

    Task { await session.removeSource(source.id) }
    try await waitUntil { session.operationState == .removingSource(source.id) }
    await environment.openRemoveGate()
    try await waitUntil { session.operationState == .idle }
}
```

Extend `FakeLibraryEnvironment` with gated `addSource`, `relinkSource`, and `removeSource` helpers:

```swift
private var isAddSourceGated = false
private var isAddSourceGateOpen = false
private var addSourceGateWaiters: [CheckedContinuation<Void, Never>] = []

func setAddSourceGated(_ gated: Bool) { isAddSourceGated = gated }
func openAddSourceGate() {
    isAddSourceGateOpen = true
    for waiter in addSourceGateWaiters { waiter.resume() }
    addSourceGateWaiters = []
}
```

Repeat the same pattern for relink and remove. In each fake method, suspend before returning/throwing when the gate is enabled.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
swift test --filter LibraryBrowserSessionTests/testAddSourcePublishesAddingSourceWhileDependencyIsSuspended
```

Expected: FAIL because `operationState` / gate helpers do not exist.

- [ ] **Step 3: Implement minimal operation state**

In `LibraryBrowserSession`, add `LibraryBrowserOperationState` and set/reset it with `defer`:

```swift
operationState = .addingSource
defer { operationState = .idle }
```

Use `.reconnectingSource(libraryID)` and `.removingSource(libraryID)` in the matching methods. Do not change add/relink/remove persistence behavior.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run:

```bash
swift test --filter LibraryBrowserSessionTests/testAddSourcePublishesAddingSourceWhileDependencyIsSuspended
swift test --filter LibraryBrowserSessionTests/testRelinkAndRemovePublishDistinctOperationStates
```

Expected: PASS.

- [ ] **Step 5: Run the full session test file**

Run:

```bash
swift test --filter LibraryBrowserSessionTests
```

Expected: PASS, no new skipped tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/EditorCore/LibraryBrowserSession.swift Tests/EditorCoreTests/LibraryBrowserSessionTests.swift
git commit -m "feat: expose iPad library operation state"
```

---

### Task 2: Library UI copy and source-state rendering

**Files:**
- Modify: `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadLibraryView.swift`
- Modify: `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadLibrarySidebar.swift`
- Modify: `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadLibraryGrid.swift`
- Modify: `Sources/Localization/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/Localization/Resources/zh-Hant.lproj/Localizable.strings`
- Test: `Tests/EditorCoreTests/PadLibraryCompositionContractTests.swift`
- Test: `Tests/AdjustmentUITests/PadLibraryAccessibilityContractTests.swift`

**Interfaces:**
- Consumes: `LibraryBrowserSession.operationState`, `sourceProgress`, `sources`, `selection`, `photos`, `loadState`.
- Produces: visible, localized UI copy for add/scan/reconnect/remove/offline/needs-access/no-results states.

- [ ] **Step 1: Write failing source-contract tests**

In `PadLibraryCompositionContractTests`, add tests that parse app Swift files and assert exact keys:

```swift
func testPadLibraryViewRendersDistinctSourceOperationOverlayTitles() throws {
    let source = try String(contentsOf: Self.padAppSourceURL("PadLibraryView.swift"), encoding: .utf8)

    XCTAssertTrue(source.contains("Adding source…"))
    XCTAssertTrue(source.contains("Scanning source…"))
    XCTAssertTrue(source.contains("Reconnecting source…"))
    XCTAssertTrue(source.contains("Removing source…"))
    XCTAssertTrue(source.contains("without changing your RAW files"))
}

func testPadLibraryGridHasDistinctEmptyOfflineAccessAndSearchStates() throws {
    let source = try String(contentsOf: Self.padAppSourceURL("PadLibraryGrid.swift"), encoding: .utf8)

    XCTAssertTrue(source.contains("Add a folder to start browsing RAW files"))
    XCTAssertTrue(source.contains("This source is offline"))
    XCTAssertTrue(source.contains("This source needs access"))
    XCTAssertTrue(source.contains("No photos match this search"))
    XCTAssertTrue(source.contains("No supported RAW files found"))
}
```

In `PadLibraryAccessibilityContractTests`, add:

```swift
func testSourceRowsExposeDistinctLifecycleText() throws {
    let source = try Self.loadSource("PadLibrarySidebar.swift")

    for key in ["Read-only", "Offline", "Needs Access", "Scanning…", "Partial issue"] {
        XCTAssertTrue(source.contains("L10n.t(\"\(key)\")"), "missing \(key)")
    }
    XCTAssertTrue(source.contains("RAW files and sidecars stay exactly where they are."))
}
```

- [ ] **Step 2: Run tests and verify RED**

Run:

```bash
swift test --filter PadLibraryCompositionContractTests/testPadLibraryViewRendersDistinctSourceOperationOverlayTitles
swift test --filter PadLibraryCompositionContractTests/testPadLibraryGridHasDistinctEmptyOfflineAccessAndSearchStates
swift test --filter PadLibraryAccessibilityContractTests/testSourceRowsExposeDistinctLifecycleText
```

Expected: at least one FAIL because grid/source copy is not yet complete and `Partial issue` may not be present.

- [ ] **Step 3: Implement source operation overlay**

Replace view-local operation guessing in `PadLibraryView` with a renderer that prefers `library.operationState`:

```swift
private var activeLibraryOverlay: (title: String, message: String)? {
    switch library.operationState {
    case .addingSource:
        return (L10n.t("Adding source…"), L10n.t("LumaHarbor is registering this folder without moving or changing your RAW files."))
    case .scanningSource:
        return (L10n.t("Scanning source…"), L10n.t("Refreshing the library index without changing your RAW files."))
    case .reconnectingSource:
        return (L10n.t("Reconnecting source…"), L10n.t("Checking this folder matches the original source."))
    case .removingSource:
        return (L10n.t("Removing source…"), L10n.t("RAW files and sidecars stay exactly where they are."))
    case .idle:
        return hasActiveSourceScan ? (L10n.t("Scanning source…"), L10n.t("Refreshing the library index without changing your RAW files.")) : nil
    }
}
```

Keep picker presentation state (`isAddingSource`) view-local.

- [ ] **Step 4: Implement source row and grid state copy**

In `PadLibrarySidebar.statusMessage(for:)`, render failed scan as `Partial issue` when `indexedCount > 0 || failedCount > 0`, otherwise `Scan problem`:

```swift
case .failed:
    return progress.indexedCount > 0 || progress.failedCount > 0 ? L10n.t("Partial issue") : L10n.t("Scan problem")
```

In `PadLibraryGrid.emptyState`, branch by current selection and known source state:

```swift
private var emptyStateTitle: String {
    if !library.searchText.isEmpty { return L10n.t("No photos match this search") }
    if case .source(let id) = library.selection, let folder = library.folder(for: id) {
        switch folder.connectionState {
        case .offline: return L10n.t("This source is offline")
        case .needsAuthorization: return L10n.t("This source needs access")
        case .ready, .readOnly: break
        }
    }
    return library.sources.isEmpty ? L10n.t("Add a folder to start browsing RAW files") : L10n.t("No supported RAW files found")
}
```

Add matching description text with next-step guidance.

- [ ] **Step 5: Add localization keys**

Add English and Traditional Chinese entries for every new key. Required keys:

```text
LumaHarbor is registering this folder without moving or changing your RAW files.
Add a folder to start browsing RAW files
This source is offline
This source needs access
No photos match this search
No supported RAW files found
Connect the drive again, or make the Files location available, then reconnect the source.
Choose the original folder again so LumaHarbor can verify it is the same source.
Partial issue
```

- [ ] **Step 6: Run focused tests and full UI contract tests**

Run:

```bash
swift test --filter PadLibraryCompositionContractTests
swift test --filter PadLibraryAccessibilityContractTests
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadLibraryView.swift Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadLibrarySidebar.swift Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadLibraryGrid.swift Sources/Localization/Resources/en.lproj/Localizable.strings Sources/Localization/Resources/zh-Hant.lproj/Localizable.strings Tests/EditorCoreTests/PadLibraryCompositionContractTests.swift Tests/AdjustmentUITests/PadLibraryAccessibilityContractTests.swift
git commit -m "feat: clarify iPad library feedback states"
```

---

### Task 3: Editor RAW open and save-state copy

**Files:**
- Modify: `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorView.swift`
- Modify: `Sources/Localization/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/Localization/Resources/zh-Hant.lproj/Localizable.strings`
- Test: `Tests/EditorCoreTests/PadLibraryCompositionContractTests.swift`
- Test: `Tests/EditorCoreTests/EditorSessionDocumentPersistenceTests.swift`

**Interfaces:**
- Consumes: existing `EditorSession.saveState`, `decodeFailed`, `displayedImage`, `isReadOnly`.
- Produces: user-visible `Save failed` text and RAW-safe save failure guidance.

- [ ] **Step 1: Write failing UI copy test**

Add:

```swift
func testPadEditorUsesSaveFailedCopyAndRawSafetyHint() throws {
    let source = try String(contentsOf: Self.padAppSourceURL("PadEditorView.swift"), encoding: .utf8)

    XCTAssertTrue(source.contains("Save failed"))
    XCTAssertFalse(source.contains("L10n.t(\"Not saved\")"))
    XCTAssertTrue(source.contains("Your RAW original was not changed."))
    XCTAssertTrue(source.contains("Decoding RAW…"))
}
```

- [ ] **Step 2: Run and verify RED**

Run:

```bash
swift test --filter PadLibraryCompositionContractTests/testPadEditorUsesSaveFailedCopyAndRawSafetyHint
```

Expected: FAIL because `PadEditorView` still uses `Not saved` and does not show the RAW-safety hint.

- [ ] **Step 3: Implement save failure copy**

In `PadEditorView.saveStatusIndicator`, change `.failed` branch to:

```swift
case .failed(let message):
    VStack(alignment: .leading, spacing: 4) {
        Label(L10n.t("Save failed"), systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
        Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
        Text(L10n.t("Your RAW original was not changed."))
            .font(.caption)
            .foregroundStyle(.secondary)
    }
```

Keep `.unchanged`/`.saved` as `Saved`, `.pending` as `Unsaved`, and `.saving` as `Saving…`.

- [ ] **Step 4: Add localization keys**

Add:

```text
Save failed
Your RAW original was not changed.
```

Keep the old `Not saved` key only if other UI still uses it; do not remove translations unless `rg` proves no committed code references them.

- [ ] **Step 5: Run focused behavior tests**

Run:

```bash
swift test --filter EditorSessionDocumentPersistenceTests/testSaveFailureIsNeverReportedAsSaved
swift test --filter PadLibraryCompositionContractTests/testPadEditorUsesSaveFailedCopyAndRawSafetyHint
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorView.swift Sources/Localization/Resources/en.lproj/Localizable.strings Sources/Localization/Resources/zh-Hant.lproj/Localizable.strings Tests/EditorCoreTests/PadLibraryCompositionContractTests.swift Tests/EditorCoreTests/EditorSessionDocumentPersistenceTests.swift
git commit -m "feat: clarify iPad editor save failure feedback"
```

---

### Task 4: Final verification, docs, and Claude handoff

**Files:**
- Modify: `docs/coordination/CURRENT.md`
- Create: `docs/testing/reports/2026-09-01-ipad-ui-ux-state-feedback-polish.md`

**Interfaces:**
- Consumes: commits from Tasks 1-3 and their test outputs.
- Produces: final implementation evidence and a bounded Claude review handoff.

- [ ] **Step 1: Run full automated verification**

Run:

```bash
swift test --filter LibraryBrowserSessionTests
swift test --filter PadLibraryCompositionContractTests
swift test --filter PadLibraryAccessibilityContractTests
swift test --filter PhotoDocumentEditorLibraryOpenTests
swift test
git diff --check
rg -n "/Users/|/Volumes/|/private/|7KM4ZM25P3|teamIdentifier:" docs Sources Apps Tests
```

Expected:

- focused tests PASS;
- full `swift test` PASS;
- `git diff --check` has no output;
- privacy scan has no real private path or signing leak. Regex strings inside documentation are allowed only if clearly synthetic.

- [ ] **Step 2: Run iPad generic build if available**

Run:

```bash
xcodebuild -project Apps/LumaHarborPad.xcodeproj -scheme LumaHarborPad -destination 'generic/platform=iOS' build
```

Expected: PASS. If signing/tooling blocks the build, record the exact blocking reason as `NOT RUN` or `FAIL`; do not convert it to PASS.

- [ ] **Step 3: Write verification report**

Create `docs/testing/reports/2026-09-01-ipad-ui-ux-state-feedback-polish.md` with:

```markdown
# iPad UI/UX State Feedback Polish Report

Date: 2026-09-01
Branch: `codex/ipad-ui-ux-state-feedback-polish`
Base: `f38f3ad7968b2d5faaffa96dda17f308a982846d`

## Summary

Status: IN REVIEW

## Commits

- `<sha>` — `feat: expose iPad library operation state`
- `<sha>` — `feat: clarify iPad library feedback states`
- `<sha>` — `feat: clarify iPad editor save failure feedback`

## Automated verification

| Gate | Result | Evidence |
|---|---|---|
| LibraryBrowserSessionTests | PASS/FAIL/NOT RUN | command and result |
| PadLibraryCompositionContractTests | PASS/FAIL/NOT RUN | command and result |
| PadLibraryAccessibilityContractTests | PASS/FAIL/NOT RUN | command and result |
| PhotoDocumentEditorLibraryOpenTests | PASS/FAIL/NOT RUN | command and result |
| swift test | PASS/FAIL/NOT RUN | executed/skipped/failures |
| git diff --check | PASS/FAIL/NOT RUN | output |
| privacy scan | PASS/FAIL/NOT RUN | redacted summary |
| iPad generic build | PASS/FAIL/NOT RUN | output summary |

## Manual iPad verification

Status: NOT RUN until the user runs the real-device checklist.

## Claude review request

Claude should independently review the final diff against `docs/superpowers/specs/2026-09-01-ipad-ui-ux-state-feedback-polish-design.md`, focusing on visible UI state, RAW-safety copy, privacy, and whether any skipped/unrun gate is mislabeled.
```

- [ ] **Step 4: Update CURRENT**

Update `docs/coordination/CURRENT.md`:

- active branch stays `codex/ipad-ui-ux-state-feedback-polish`;
- latest implementation commit is the current HEAD;
- latest evidence report path is `docs/testing/reports/2026-09-01-ipad-ui-ux-state-feedback-polish.md`;
- next action is Claude independent review or user real-device smoke test, depending on what was run.

- [ ] **Step 5: Commit report**

```bash
git add docs/testing/reports/2026-09-01-ipad-ui-ux-state-feedback-polish.md docs/coordination/CURRENT.md
git commit -m "docs: record iPad UI state feedback verification"
```

---

## Plan self-review

Spec coverage:

- Adding/scanning/reconnecting/removing/loading/opening/decoding states: Tasks 1-3.
- Ready/read-only/offline/needs-access/scanning/partial issue: Task 2.
- Remove-source non-destructive copy: Task 2.
- RAW original safety copy: Tasks 2-3.
- Privacy and sensitive-data constraints: Task 4.
- TDD and automated verification: every implementation task has RED/GREEN steps; Task 4 has full verification.
- Manual APFS/exFAT/Files/Sony ARW verification remains a final smoke gate and is intentionally not claimed by automated tests.

Known bounded concerns:

- SwiftUI app files under `Apps/LumaHarborPad.swiftpm` are primarily protected by source-parsing contract tests because the root SwiftPM test target cannot instantiate that app package's view hierarchy directly.
- The plan does not require exact scan percentage, because the scanner may not know a total count up front; visible indeterminate progress plus indexed/failed counts is acceptable.
