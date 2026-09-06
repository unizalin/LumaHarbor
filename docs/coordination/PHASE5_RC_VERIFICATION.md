# Phase 5 RC Verification Report

**Report type**: read-only audit + automated verification only. No GUI was
started, no person operated a keyboard/mouse against the app, and no A11 or
Phase 4.6 work was attempted while producing this report — see "Known
limitations" below for exactly what that leaves un-verified.

**Branch**: `claude/awayphotoraweditor-parity-phase2-geometry`

**HEAD at time of this report**: `eef40979ee181a68ec8851ec2c873f21e72989d7` (`eef4097`)

**Phase 5 commit range**: `5702c9a`..`eef4097` (11 commits; `5702c9a` is the last
pre-Phase-5.1-UI-wiring commit, included here because it's the batch export
core model's own path-free-report follow-up):

```
5702c9a fix: keep batch export failure reports path-free
1c09e59 feat: wire Mac batch export queue UI to LibraryViewModel (Phase 5 Task 5.1)
0a2511f feat: add export naming template engine (Phase 5 Task 5.2)
8c05dcf feat: add export collision policy (increment/skip/ask) (Phase 5 Task 5.2)
7331230 feat: add export watermark rendering (Phase 5 Task 5.2)
6a246d7 feat: wire naming template, collision policy, watermark into Mac export UI (Phase 5 Task 5.2)
a309a99 docs: record Phase 5 Task 5.2 rename/DPI/EXIF/collision/watermark completion
b248aa1 feat: add Mac theme preference system (Phase 5 Task 5.3)
e007fcc test: add eight-language localization coverage gate (Phase 5 Task 5.4)
84a5659 feat: add headless diagnostics runner (Phase 5 Task 5.5)
eef4097 fix: harden Phase 5 diagnostics and preferences (integration hardening pass)
```

No commits were made while producing this report — it is documentation
only, added in its own commit alongside the `CURRENT.md` pointer.

---

## Phase 5 feature matrix

| # | Feature | Status | Primary automated tests |
|---|---|---|---|
| 5.1 | Batch export queue + Mac UI/action wiring | **PASS** (automated) | `BatchExportQueueTests` (RawProcessingCoreTests, 9), `BatchExportQueueWiringTests` (LumaHarborAppTests, 6), `BatchExportSheetContractTests` (15) |
| 5.2 | Export Pro: naming template / collision policy / watermark / DPI / EXIF policy | **PASS** (automated) | `ExportNamingTemplateTests` (12), `ExportCollisionPolicyTests` (9), `WatermarkRendererTests` (10), `ExportOptionsWiringTests` (5), `ExportSheetContractTests` (15), `PhotoExportTests` (DPI/EXIF cases carried over from Phase 1 Task 4) |
| 5.3 | Theme preference: System/Light/Dark + Settings scene + `preferredColorScheme` wiring | **PASS** (automated; **simplified scope**, see note) | `AppThemeTests` (8), `SettingsViewContractTests` (6, incl. this round's `preferredColorScheme` self-application fix) |
| 5.4 | Eight-language localization coverage gate | **PASS** (automated coverage only; **translation quality NOT human-reviewed**) | `EightLanguageLocalizationGateTests` (9), `LocalizationSmokeTest` (17) |
| 5.5 | Headless diagnostics CLI / runner | **PASS** (automated; **deliberately narrower than roadmap's own 4-command list**, see note) | `LumaHarborDiagnosticsRunnerTests` (14) |
| — | Integration hardening pass | **PASS** (automated) | Same test files as above, plus the 4 fixes verified in this pass's own commit (`eef4097`) |
| 5.6 | RC verification | **PARTIAL** (this report covers the automatable subset only) | See "RC verification sub-item status" below |

**Phase 5.3 note**: this is the simplified System/Light/Dark `ColorScheme`
picker built per an explicit user instruction partway through Phase 5,
**not** the roadmap's own two custom palettes (classic dark / warm paper)
or its "design tokens for photo-neutral background vs app chrome". This
was already recorded honestly in `CURRENT.md`'s Phase 5.3 entry and is
repeated here so this report doesn't imply more than what shipped.

**Phase 5.4 note**: `en` and `zh-Hant` are human-maintained across all of
Phase 1-5. `ja`/`ko`/`zh-Hans`/`de`/`fr`/`es` are LLM-authored
machine-assisted translations added in Phase 5 Task 5.4, per the
roadmap's own explicit allowance for this task ("Initial translations may
be rough but must be marked machine-assisted in docs if not human
reviewed"). They have **not** been reviewed by a native speaker of any of
those six languages. The gate proves *coverage and structure* (every key
present, non-empty, no placeholder text, no silently-unallowlisted match
to English) — it does not and cannot prove translation quality, grammar,
or that no string visually truncates in a real, narrower UI control.

**Phase 5.5 note**: the roadmap's own Task 5.5 lists four commands —
`selftest`, `exporttest`, `shot`, `gallery`. Only a `selftest`/`exporttest`-
*flavored* capability-check runner was built (localization/theme/export/
batch-export capability plus three optional fixture-directory checks).
`shot` (open the fixture library and screenshot the UI) and `gallery`
(thumbnail/preview regression evidence) were not built at all — both
require a real window and real fixture photos, which contradicts this
phase's own "headless, no person at the keyboard" requirement. This was a
deliberate, explicitly-instructed scope decision at the time (Phase 5 Task
5.5's own prompt), not an oversight, and is repeated here for RC-review
visibility.

---

## RC verification sub-item status (roadmap Task 5.6's own checklist)

| Sub-item | Status | Note |
|---|---|---|
| Full `swift test` | **PASS** | 1721 tests, 9 skipped, 0 failures (this report's own run — see "Automated verification results" below) |
| Mac app build | **PASS** | `swift build` succeeds; `LumaHarbor` executable target links |
| iOS generic build | **NOT RUN** | Out of scope for this round by explicit instruction ("不要碰 iPad 相關檔案"); the iPad app is a separate nested SwiftPM manifest not touched by this report |
| MVP acceptance if fixtures available | **SKIPPED** | No `LUMAHARBOR_RAW_FIXTURE_DIR`/`LUMAHARBOR_APFS_TEST_DIR`/`LUMAHARBOR_EXFAT_TEST_DIR` configured in this environment; `Scripts/run-mvp-acceptance.zsh` and the diagnostics CLI both correctly report this as skipped, not failed |
| Export fixture tolerance report | **NOT RUN** | Needs real RAW fixtures (see above); the automated `PhotoExportTests`/`WatermarkRendererTests` suites cover pixel-level behavior against *synthetic* fixtures only, which is a real but narrower guarantee |
| Manual Mac checklist | **NOT RUN** | Requires a person operating the GUI; explicitly out of scope this round |
| iPad subset checklist | **NOT RUN** | Requires the iPad app and a person operating it; out of scope this round (iPad files untouched) |
| Privacy scan | **PASS** | See "Privacy scan results" below |
| Independent review | **NOT RUN** | Requires a second reviewer (human or a separate agent session); not attempted this round |

---

## Automated verification results

All commands below were run from this worktree, this session, against HEAD `eef4097`.

### `swift build`
```
Build complete! (~1s, incremental)
```

### `swift run LumaHarborDiagnosticsCLI` (text output)
```
localization.eightLanguages: PASS -- all 8 required languages ship a readable Localizable.strings
theme.preference: PASS -- no stored preference yet; default (system) applies
export.formatsCapability: PASS -- 4 formats defined, 4 encodable on this build
batchExport.queueCapability: PASS -- BatchExportQueue constructs with its default PhotoExporter
fixture.rawDirectory: SKIPPED -- LUMAHARBOR_RAW_FIXTURE_DIR is not set (set LUMAHARBOR_RAW_FIXTURE_DIR to run this check; see Scripts/run-mvp-acceptance.zsh for the same convention)
fixture.apfsTestDirectory: SKIPPED -- LUMAHARBOR_APFS_TEST_DIR is not set (set LUMAHARBOR_APFS_TEST_DIR to run this check; see Scripts/run-mvp-acceptance.zsh for the same convention)
fixture.exfatTestDirectory: SKIPPED -- LUMAHARBOR_EXFAT_TEST_DIR is not set (set LUMAHARBOR_EXFAT_TEST_DIR to run this check; see Scripts/run-mvp-acceptance.zsh for the same convention)
SUMMARY: 4 pass, 0 warning, 0 fail, 3 skipped -- overall PASS
```
Exit code: `0`. No path (real or synthetic) appears anywhere in this output.

### `swift run LumaHarborDiagnosticsCLI --json` (JSON contract)
Top-level shape (values match the text run above):
```json
{
  "checks": [ /* 7 objects, each {id, title, message, status, remediation?} */ ],
  "overallStatus": "pass",
  "summary": { "pass": 4, "warning": 0, "fail": 0, "skipped": 3 }
}
```
`overallStatus` and `summary` were added in this Phase's own integration
hardening commit (`eef4097`) after this report's audit re-confirmed the
JSON contract still includes them (previously the synthesized `Codable`
only emitted `checks`, a gap fixed and tested in that commit). Exit code: `0`.

### Focused test filters
| Filter | Result |
|---|---|
| `Diagnostics` | 21 tests, 0 failures |
| `EightLanguageLocalizationGateTests\|LocalizationSmokeTest` | 26 tests, 0 failures |
| `AppThemeTests\|SettingsViewContractTests` | 14 tests, 0 failures |
| `ExportNamingTemplateTests\|ExportCollisionPolicyTests\|WatermarkRendererTests` | 31 tests, 0 failures |
| `ExportSheetContractTests\|BatchExportSheetContractTests\|ExportOptionsWiringTests` | 35 tests, 0 failures |
| `BatchExportQueueTests\|BatchExportQueueWiringTests` | 17 tests, 0 failures |

### Full `swift test`
```
Executed 1721 tests, with 9 tests skipped and 0 failures (0 unexpected)
```
The 9 skips are the project's existing, pre-Phase-5 fixture-gated
integration tests (real RAW files / real APFS-exFAT drives), unrelated to
this Phase 5 audit's own scope — they skip the same way with or without
this report.

### `git diff --check`
`PASS` (exit 0) both before this report's own doc-only commit and after it.

---

## Privacy scan results

Scanned every Phase 5-relevant source and test file (`Sources/LumaHarborApp/
Diagnostics/*`, `Sources/LumaHarborDiagnosticsCLI/*`, `ExportSheet.swift`,
`BatchExportSheet.swift`, `SettingsView.swift`, `LibraryViewModel.swift`,
`Sources/RawProcessingCore/Export/*`, all eight `Localizable.strings`,
and every Diagnostics/Localization/Export/Theme/Settings test file, plus
`Package.swift`) for `/Users/`, `/Volumes/`, `/private/`,
`DEVELOPMENT_TEAM`, `PROVISIONING_PROFILE`, `TEAM_ID`, `UDID`.

Three hits, all pre-existing synthetic test fixtures from earlier Phase 5
rounds, each already self-documented in the file it appears in as fake:

1. `Tests/LumaHarborAppTests/LumaHarborDiagnosticsRunnerTests.swift:75` —
   `"/Users/private-test-user/Secret RAW Fixtures/Do Not Print"`, the
   test's own doc comment: "never created on disk... not meant to resemble
   a real fixture location."
2. `Tests/RawProcessingCoreTests/BatchExportQueueTests.swift:217` —
   `"/Users/private-name/Pictures/DSC0001.ARW"`, used by
   `testFailedStatusMessageNeverIncludesTheSourceFilesAbsolutePath` to
   prove per-file failure messages never leak it.
3. `Tests/RawProcessingCoreTests/PhotoExportTests.swift:550-551` —
   `"/Volumes/SSD"`, a pre-existing (Phase 1) synthetic fixture in
   `testEveryExportErrorOffersANextStep`.

No real user path, no Team ID, no UDID, no provisioning profile content
anywhere in the scanned set. This report's own diff (this file plus the
`CURRENT.md` pointer) is documentation-only and contains no paths at all.

---

## Known limitations

- **A11 (physical ⌘Z/⌘⇧Z keyboard verification) is `NOT RUN`.** This has
  been true since Phase 4 and remains true after this report. No attempt
  was made this round, per explicit instruction.
- **Phase 4.6 final manual acceptance is not done.** Not attempted this
  round, per explicit instruction.
- **No real-person visual QA was performed** on any Phase 5 UI (export
  sheet, batch export sheet, Settings/theme picker) in any of the eight
  languages or either explicit color scheme. Everything in this report is
  automated/source-level verification only.
- **The six machine-assisted languages (ja/ko/zh-Hans/de/fr/es) have not
  been reviewed by a native speaker.** The coverage gate proves structure,
  not linguistic quality, grammar, or that longer translated strings don't
  visually truncate in a real (narrower) AppKit/SwiftUI control at a real
  window size.
- **The naming template's "Preset Name + Original Filename" option always
  falls back to the plain original filename.** No part of the app tracks
  "which preset was last applied to this photo", so `presetName` is always
  `nil` when building the naming context. This is unchanged from Phase 5.2
  and the Phase 5 integration hardening pass, both of which already
  documented it; repeated here because it's real, user-visible behavior
  that a naive reading of the picker's label wouldn't predict.
- **Headless diagnostics does not decode a real RAW file, does not run a
  real export, and does not inspect a signed `.app` bundle's resources.**
  `export.formatsCapability`/`batchExport.queueCapability` prove the
  capability *constructs*, not that an end-to-end export against a real
  camera file actually produces correct pixels — that guarantee currently
  lives only in `PhotoExportTests`'s synthetic-fixture suite. App-bundle
  resource lookup was evaluated and deliberately skipped in Phase 5.5:
  `swift test`/`swift run` have no signed `.app` bundle for `Bundle.main`
  to mean anything, so a check here would either be meaningless or require
  fabricating a fake bundle context.
- **`selftest`/`exporttest`/`shot`/`gallery` (roadmap Task 5.5's own
  four-command list) are not built as such.** What exists today is closer
  in spirit to `selftest` (capability/wiring checks) than to a literal
  implementation of any of the four; `shot` and `gallery` were not
  attempted at all (see the Phase 5.5 feature-matrix note above for why).
- **iOS generic build, iPad subset checklist, and independent review are
  all `NOT RUN`** for this RC pass — the first two require touching iPad
  files or an iPad target (out of scope this round), the third requires a
  second reviewer this session didn't have.

---

## RC conclusion

Every Phase 5 sub-feature (5.1-5.5) and the integration hardening pass
that followed have full, currently-green automated coverage at their own
documented scope, and that scope is accurately reflected in
`docs/coordination/CURRENT.md`'s per-task entries. `swift build`, the full
`swift test` suite, and the diagnostics CLI (both text and `--json`) all
pass cleanly with no privacy leaks in the scanned surface.

**This does not mean Phase 5 (or the app) is ready to ship or ready for a
real release candidate tag.** The gates this report can run (build, unit/
contract tests, headless diagnostics, static privacy scan) are exactly
the ones that don't need a person, a signed app, or real camera files —
and roadmap Task 5.6 itself lists several sub-items (manual Mac checklist,
iPad subset checklist, independent review, export fixture tolerance
report against real RAW files) that fundamentally can't be satisfied by
that same automation. Those, plus A11 and Phase 4.6, remain the real
blockers between "Phase 5 code is done and tested" and "RC".

## Next recommended actions

1. **Real A11 physical-keyboard verification** (⌘Z/⌘⇧Z on real hardware) —
   still the single longest-standing NOT RUN item, blocking Phase 4.6.
2. **Phase 4.6 final manual acceptance**, once A11 clears.
3. **Native-speaker review of ja/ko/zh-Hans/de/fr/es**, plus a visual
   truncation pass once a person can actually run the app in each
   language (longer German/French strings are the most likely to clip in
   a fixed-width control).
4. **Optional**: if the roadmap's original classicDark/warmPaper custom
   theme vision (plus "photo-neutral background vs app chrome" design
   tokens) is still wanted, that is a distinct follow-up scoped beyond
   this Phase 5's simplified System/Light/Dark picker — needs an explicit
   decision before starting, since it's a real design task, not a wiring
   task.
5. **Optional**: expand headless diagnostics to a real RAW decode/export
   pass (closer to roadmap's own `exporttest`) once `LUMAHARBOR_RAW_FIXTURE_DIR`
   is available in whatever environment runs this next, following the
   same `XCTSkip`-when-absent convention `RawFixtureTests.swift` and
   `Scripts/run-mvp-acceptance.zsh` already use.
6. **Manual Mac checklist + iPad subset checklist + independent review**,
   all still requiring a person, once the above are further along.
