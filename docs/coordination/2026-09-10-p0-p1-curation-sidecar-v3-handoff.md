# Handoff: P0 baseline protection + P1 curation sidecar v3 and migration

Follows `docs/coordination/HANDOFF_TEMPLATE.md`.

## Status

`DONE`

## Git state

- Source branch: `claude/professional-editing-completion`
- Full HEAD commit SHA at handoff time: will be the commit that adds this file plus `docs/coordination/CURRENT.md` and `docs/coordination/DECISIONS.md` (D-006), immediately after `d7bc821ecb05c6381248605494185d9d6cabe644`.
- Base branch: `main`.
- Ahead/behind: this branch was not compared against `main`'s current tip during this task; only local commit history on this branch was inspected. No fetch or rebase was performed.
- Upstream: not checked/changed this session.
- Push, merge, or rebase: none occurred. No destructive git operation was run.

## Changes

Commits, in order, starting from `4cd43e5` (`docs: define professional editing completion spec`, the task's starting HEAD):

1. `787c9d2` — `docs: plan curation sidecar v3 and migration` — adds `docs/superpowers/plans/2026-09-10-curation-sidecar-v3-and-migration.md`.
2. `8330ad0` — `test: pin sidecar compatibility and curation-durability baseline` (P0) — adds `Tests/PhotoLibraryCoreTests/SidecarSchemaCompatibilityTests.swift`, `Tests/PhotoLibraryCoreTests/CurationDurabilityTests.swift`; extends `Tests/PhotoLibraryCoreTests/TestSupport.swift` with `LegacySidecarFixture`.
3. `030c2af` — `feat: add portable PhotoCuration model` — adds `Sources/PhotoLibraryCore/Model/PhotoCuration.swift` and its tests.
4. `a45a780` — `feat: add curation to PhotoSidecar schema v3` — `Sources/PhotoLibraryCore/Sidecar/PhotoSidecar.swift` gains `curation` and custom `Codable`; `currentSchemaVersion` is now `3`.
5. `c0c200d` — `feat: add pure curation migration decision function` — adds `Sources/PhotoLibraryCore/Service/CurationMigration.swift`.
6. `6863a2b` — `feat: add SQLite schema v5 curation snapshot and pending flag` — `PhotoIndexStore.schemaVersion` is now `5`; adds `curation_migration_pending` column, `curationSnapshot(inLibrary:)`, `setCurationMigrationPending(_:for:)`; `PhotoAsset` gains `curationMigrationPending`.
7. `77ed2db` — `fix: hydrate and migrate curation from sidecar during scan` — `PhotoLibraryService.performScan` now runs the migration decision per photo and projects the result into SQLite after the batch upsert (not before — `photo_keyword`'s foreign key made an earlier ordering fail silently; this was caught and fixed within this same task, not left for a follow-up).
8. `ca836b1` — `feat: make PhotoLibraryService curation mutations sidecar-first` — adds `curation(for:)`/`setRating(_:for:)`/`setFlag(_:for:)`/`setKeywords(_:for:)`; also fixes a latent bug where `saveAdjustments` would have silently reset curation to neutral on every adjustment save.
9. `1af8e84` — `fix: route Mac rating/flag/keyword edits through the sidecar-first API` — `LibraryViewModel`'s three curation setters now call `PhotoLibraryService`, not `PhotoIndexStore` directly.
10. `d7bc821` — `fix: route iPad rating/flag/keyword edits through the sidecar-first API` — same fix in `PadBatchAdjustmentCoordinator`.
11. (this commit) — `docs/coordination/DECISIONS.md` (D-006), `docs/coordination/CURRENT.md`, this handoff file.

No file outside `Sources/PhotoLibraryCore/*`, `Sources/LumaHarborApp/ViewModels/LibraryViewModel.swift`, `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadBatchAdjustmentCoordinator.swift`, `Tests/*`, `docs/coordination/*`, and the one new plan document was modified. In particular `Sources/RawProcessingCore/Model/AdvancedToneCurve.swift`, `Sources/AdjustmentUI/CurveAdjustmentPanel.swift`, and `Sources/AdjustmentUI/HistogramPanel.swift` (the just-merged P0 curve/histogram baseline) are untouched — verified with `git diff --stat 4cd43e5 HEAD -- <those three paths>` producing no output.

### Behavior changes

- Rating/flag/keywords are now authoritative in the portable sidecar (`PhotoSidecar` schema v3), not SQLite. SQLite (`PhotoIndexStore`) is a rebuildable projection of it, matching how `adjustments` already worked.
- A legacy (schema < 3) sidecar with non-neutral SQLite curation migrates onto a new v3 sidecar automatically on the next scan of that source. A photo with no sidecar at all but non-neutral SQLite curation gets a brand-new v3 sidecar created, with neutral `adjustments` — the photo does not need to have been edited first.
- If the migration write fails (offline, read-only, out of space), the old SQLite values are kept and the row is marked `curationMigrationPending`; the very next scan retries the same decision from scratch. There is no separate retry queue.
- Deleting the local SQLite index and rescanning now fully restores rating/flag/keywords from sidecars (previously this data was silently lost — this was the P0-documented gap that P1 closes).
- A virtual copy still always starts with neutral curation (rating 0, no flag, no keywords), even if the original it was copied from is rated/flagged, and this survives a rescan.
- `saveAdjustments` no longer silently resets a photo's curation to neutral when saving an adjustment (a latent bug found and fixed during this task, not present in any shipped behavior since curation only existed in SQLite before now, but would have broken the very first time `saveAdjustments` ran after this task's sidecar field was added, had it not been caught).
- Mac (`LibraryViewModel`) and iPad (`PadBatchAdjustmentCoordinator`) both now call `PhotoLibraryService.setRating/setFlag/setKeywords` instead of `PhotoIndexStore.setRating/setFlag/setKeywords` directly.

## Verification

All commands below were actually run in this worktree during this task, most recently against HEAD `d7bc821`:

- `swift test` (full suite) → **PASS**. 1966 executed, 9 skipped, 0 failures. (Skips are the same 9 pre-existing fixture-dependent skips as before this task; no new skip was introduced.)
- `swift build -Xswiftc -strict-concurrency=complete` → **PASS**, exit 0.
- `xcodebuild -project Apps/LumaHarborPad.xcodeproj -scheme LumaHarborPad -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build` → **PASS**, `** BUILD SUCCEEDED **`.
- `git diff --check 4cd43e5 HEAD` → **PASS**, no output.
- `rg -n 'TBD|TODO|FIXME|fatalError|try!'` over every changed production `.swift` file (`Sources/PhotoLibraryCore/{Model/PhotoCuration.swift,Sidecar/PhotoSidecar.swift,Service/CurationMigration.swift,Service/PhotoLibraryService.swift,Index/PhotoIndexStore.swift,Model/PhotoAsset.swift}`, `Sources/LumaHarborApp/ViewModels/LibraryViewModel.swift`, `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadBatchAdjustmentCoordinator.swift`) → **PASS**, no hits.
- Privacy scan (`rg` for `/Users/…`, `/Volumes/…`, `DEVELOPMENT_TEAM`, private-key headers) over every file changed since `4cd43e5` → **PASS**. The only hits are pre-existing synthetic fixture paths already used by this test suite's own conventions (`/Volumes/SSD` in `SidecarRepositoryTests.swift`, `/Volumes/Cardinality` in `PhotoIndexQueryTests.swift`) and the plan document's own description of this exact scan command; none are real private paths, accounts, or credentials.

Not run in this task (genuinely unavailable, not skipped by choice):

- `Scripts/run-mvp-acceptance.zsh` (full MVP acceptance) — **NOT RUN**. Requires exported private RAW/APFS/exFAT fixture directories, which were not exported this session.
- Real M1+ iPad manual UI verification — **NOT RUN**. No physical device was connected this session, and this task's changes are confined to `PhotoLibraryCore`/`PhotoLibraryService`/two call sites, not to any rendering or device-specific code path. Recommended before this branch's cumulative work is considered release-ready, but not a blocker for handing off P1 specifically.
- Real Mac manual UI verification of the rating/flag/keyword menu and keyboard shortcuts — **NOT RUN**. The automated source-contract test (`EditorWorkflowUXContractTests.testLibraryViewModelCurationMutationsGoThroughLibraryServiceNotIndexStoreDirectly`) and the full `PhotoLibraryServiceCurationTests` integration suite cover the underlying behavior; the UI itself (menu items, keyboard shortcuts) was not touched by this task, only the call target inside existing handler functions.

## Dirty files

None. `git status --short` shows a clean worktree once this handoff commit lands (verify with `git status --short --branch` after committing).

## Concerns and blockers

- **Unknown top-level JSON key preservation**: `PhotoSidecar`'s custom `Codable` only reads keys it knows about. If a future requirement needs literal preservation of unrelated/future top-level JSON keys through a read-modify-write cycle (e.g. a newer build's field surviving being opened by this build and saved again), that needs a raw-JSON merge strategy this task did not implement. Not currently required by any P0/P1 acceptance criterion, but flagged here as a known limitation rather than silently assumed solved.
- **`snapshots` deferred to P6**: recorded as `docs/coordination/DECISIONS.md` D-006. The next agent working on P6 (Snapshot/Soft Proof) must read that decision before bumping `PhotoSidecar.currentSchemaVersion` again.
- **No real-device gate exercised this task**: see "Not run" above. Low risk given the change surface, but should not be conflated with "fully verified" for any future release-readiness claim.

## Next action

Start P2, "Shared Professional Inspector Catalog" (`docs/superpowers/specs/2026-09-10-professional-editing-completion-design.md` §16 item 2 — file `2026-09-10-shared-professional-inspector-catalog.md` does not exist yet and must be authored first, same as this task authored its own plan before coding). Files in scope per the spec's dependency graph (§9): `Sources/AdjustmentUI/*` (shared catalog, search, favorites, smart follow, pin), `Sources/LumaHarborApp/Views/InspectorView.swift` (Mac adaptive host), `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorView.swift` (remove iPad's own duplicate catalog/host). Do not start P3 (per-channel tone curves), P4, or P5 before P2 lands — the spec's dependency graph requires P0 before P2, and P2 has no other prerequisite, but skipping straight to P3+ before P2 would leave two divergent inspector implementations only postponed, not solved. Do not modify `AdvancedToneCurve.swift`/`CurveAdjustmentPanel.swift`/`HistogramPanel.swift`'s actual curve logic as part of P2 — P2 is container/catalog work only; P3 owns the curve model itself.

## Suggested skills

- `test-driven-development` — every task in this area should continue red/green, matching how this task's own `CurationMigration` and scan-hydration work was built.
- `verification-before-completion` — before claiming P2 complete, rerun the same verification matrix as this handoff (full `swift test`, strict-concurrency build, iPad simulator build, `git diff --check`, privacy scan).
- `handoff` — use again when P2 ownership changes.
