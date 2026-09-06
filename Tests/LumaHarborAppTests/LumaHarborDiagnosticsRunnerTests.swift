import Foundation
import XCTest
@testable import LumaHarborApp

/// Roadmap Phase 5 Task 5.5: headless diagnostics. `LumaHarborDiagnosticsRunner`
/// checks core capabilities (localization, theme, export, batch export) and
/// optional real-fixture directories without starting the GUI, opening a
/// window, or needing a person at the keyboard -- every test in this file
/// is a plain synchronous call to `LumaHarborDiagnosticsRunner.run(environment:)`.
///
/// Deliberately narrower than the roadmap's own four-command wishlist
/// (`selftest`/`exporttest`/`shot`/`gallery`) per this round's explicit
/// instruction: `shot` and `gallery` need a real window and real fixture
/// photos to screenshot, which contradicts "headless" and "no person at the
/// keyboard" -- see `docs/coordination/CURRENT.md`'s Phase 5 Task 5.5 entry
/// for the full scope note.
final class LumaHarborDiagnosticsRunnerTests: XCTestCase {
    // MARK: - Stable check ID contract

    func testRunnerListsExactlyTheExpectedCheckIDs() {
        let report = LumaHarborDiagnosticsRunner.run(environment: [:])
        XCTAssertEqual(
            Set(report.checks.map(\.id)),
            Set(LumaHarborDiagnosticsRunner.expectedCheckIDs),
            "the report must contain exactly the documented check IDs -- no more, no fewer"
        )
        XCTAssertEqual(report.checks.count, LumaHarborDiagnosticsRunner.expectedCheckIDs.count, "no duplicate check IDs")
    }

    func testExpectedCheckIDsCoverLocalizationThemeExportAndBatchExport() {
        let ids = Set(LumaHarborDiagnosticsRunner.expectedCheckIDs)
        XCTAssertTrue(ids.contains("localization.eightLanguages"))
        XCTAssertTrue(ids.contains("theme.preference"))
        XCTAssertTrue(ids.contains("export.formatsCapability"))
        XCTAssertTrue(ids.contains("batchExport.queueCapability"))
    }

    // MARK: - All-pass scenario (no optional fixtures configured)

    /// With no fixture directories configured, every non-fixture check must
    /// still report a real PASS (not skipped, not a fake pass) -- these
    /// checks exercise only code and resources already inside the repo, so
    /// they have no legitimate reason to be anything but green in CI.
    func testCoreCapabilityChecksPassWithNoFixturesConfigured() throws {
        let report = LumaHarborDiagnosticsRunner.run(environment: [:])
        for id in ["localization.eightLanguages", "theme.preference", "export.formatsCapability", "batchExport.queueCapability"] {
            let check = try XCTUnwrap(report.checks.first { $0.id == id }, "no check with id \(id)")
            XCTAssertEqual(check.status, .pass, "\(id) should PASS with no fixtures configured, got \(check.status)")
        }
    }

    func testOverallReportPassesWhenNoCheckFails() {
        let report = LumaHarborDiagnosticsRunner.run(environment: [:])
        XCTAssertTrue(report.passed, "a report with only pass/skipped checks must report overall passed")
    }

    // MARK: - Missing fixture env vars: skipped, never a hard failure

    func testMissingFixtureEnvVarsAreSkippedNotFailed() throws {
        let report = LumaHarborDiagnosticsRunner.run(environment: [:])
        for id in ["fixture.rawDirectory", "fixture.apfsTestDirectory", "fixture.exfatTestDirectory"] {
            let check = try XCTUnwrap(report.checks.first { $0.id == id }, "no check with id \(id)")
            XCTAssertEqual(check.status, .skipped, "\(id) must be .skipped (not .fail) when its env var isn't set")
        }
        XCTAssertTrue(report.passed, "skipped fixture checks must not fail the overall report")
    }

    // MARK: - Present fixture env vars never leak the real path

    /// Uses a fake, obviously-synthetic path (never created on disk) purely
    /// to prove the *reporting* layer never echoes back whatever value the
    /// environment handed it -- this is not meant to resemble a real
    /// fixture location.
    func testAPresentButNonexistentFixtureDirectoryNeverLeaksItsPathAndIsNotAHardFailure() throws {
        let syntheticPath = "/Users/private-test-user/Secret RAW Fixtures/Do Not Print"
        let report = LumaHarborDiagnosticsRunner.run(environment: ["LUMAHARBOR_RAW_FIXTURE_DIR": syntheticPath])

        for check in report.checks {
            for field in [check.title, check.message, check.remediation ?? ""] {
                XCTAssertFalse(field.contains(syntheticPath), "check \"\(check.id)\" leaked the raw fixture path")
                XCTAssertFalse(field.contains("/Users/"), "check \"\(check.id)\" leaked an absolute user path")
                XCTAssertFalse(field.contains("private-test-user"), "check \"\(check.id)\" leaked the username segment")
                XCTAssertFalse(field.contains("Secret RAW Fixtures"), "check \"\(check.id)\" leaked the fixture directory's own name")
            }
        }

        let rawCheck = try XCTUnwrap(report.checks.first { $0.id == "fixture.rawDirectory" })
        XCTAssertNotEqual(rawCheck.status, .fail, "a configured-but-missing fixture directory must not be a hard failure")
    }

    /// A real, valid fixture directory (created by this test, not a stand-in
    /// for any actual user data) must report PASS, and the report still
    /// must not contain that directory's own path -- proves the redaction
    /// isn't merely "only tested against a path that doesn't exist".
    func testAPresentAndValidFixtureDirectoryPassesAndStillNeverLeaksItsPath() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumaHarborDiagnosticsRunnerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let report = LumaHarborDiagnosticsRunner.run(environment: ["LUMAHARBOR_APFS_TEST_DIR": directory.path])

        let check = try XCTUnwrap(report.checks.first { $0.id == "fixture.apfsTestDirectory" })
        XCTAssertEqual(check.status, .pass)
        for field in [check.title, check.message, check.remediation ?? ""] {
            XCTAssertFalse(field.contains(directory.path), "check \"\(check.id)\" leaked the real fixture path")
            XCTAssertFalse(field.contains(directory.lastPathComponent), "check \"\(check.id)\" leaked even the fixture directory's own basename")
        }
    }

    // MARK: - Theme check does not touch the real UserDefaults.standard

    /// Integration hardening review finding: `themePreferenceCheck()`
    /// originally hardcoded `UserDefaults.standard` with no way to inject
    /// a different store, so a test could never observe its behavior for a
    /// specific stored value without writing into (and cleaning up after
    /// itself in) this process's *real* `UserDefaults.standard` domain --
    /// exactly the "test/real settings coupling" this checks against.
    func testThemeCheckReadsFromAnInjectedUserDefaultsNotTheRealStandardDomain() throws {
        let suiteName = "LumaHarborDiagnosticsRunnerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("dark", forKey: "appTheme")
        let reportWithDark = LumaHarborDiagnosticsRunner.run(environment: [:], userDefaults: defaults)
        let checkWithDark = try XCTUnwrap(reportWithDark.checks.first { $0.id == "theme.preference" })
        XCTAssertEqual(checkWithDark.status, .pass)
        XCTAssertTrue(checkWithDark.message.contains("stored preference parses"))

        defaults.set("not-a-real-theme", forKey: "appTheme")
        let reportWithGarbage = LumaHarborDiagnosticsRunner.run(environment: [:], userDefaults: defaults)
        let checkWithGarbage = try XCTUnwrap(reportWithGarbage.checks.first { $0.id == "theme.preference" })
        XCTAssertEqual(checkWithGarbage.status, .warning, "an unparseable stored value must warn, not hard-fail -- the app itself falls back to the default rather than crashing")
    }

    func testThemeCheckPassesWithNoStoredPreferenceInAFreshStore() throws {
        let suiteName = "LumaHarborDiagnosticsRunnerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let report = LumaHarborDiagnosticsRunner.run(environment: [:], userDefaults: defaults)
        let check = try XCTUnwrap(report.checks.first { $0.id == "theme.preference" })
        XCTAssertEqual(check.status, .pass)
    }

    // MARK: - Report encoding contracts (stable machine-readable + text output)

    func testReportEncodesToJSONAndRoundTrips() throws {
        let report = LumaHarborDiagnosticsRunner.run(environment: [:])
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(DiagnosticsReport.self, from: data)
        XCTAssertEqual(decoded, report)
    }

    /// Integration hardening review finding: `jsonString()`/`JSONEncoder`
    /// only encoded the `checks` array -- `passed` and the per-status
    /// counts are computed properties, which Swift's synthesized `Codable`
    /// silently drops. A machine consuming the JSON (a CI step, say) had no
    /// way to read "did this pass overall" without re-implementing this
    /// type's own pass/fail logic itself. The JSON contract must carry
    /// both explicitly.
    func testJSONReportIncludesOverallStatusAndSummaryCounts() throws {
        let report = LumaHarborDiagnosticsRunner.run(environment: [:])
        let data = try JSONEncoder().encode(report)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["overallStatus"] as? String, "pass")

        let summary = try XCTUnwrap(object["summary"] as? [String: Int])
        XCTAssertEqual(summary["pass"], report.count(.pass))
        XCTAssertEqual(summary["warning"], report.count(.warning))
        XCTAssertEqual(summary["fail"], report.count(.fail))
        XCTAssertEqual(summary["skipped"], report.count(.skipped))
    }

    func testJSONReportOverallStatusReflectsAFailingCheck() throws {
        let report = DiagnosticsReport(checks: [
            DiagnosticCheck(id: "x", title: "X", message: "broken", status: .fail),
        ])
        let data = try JSONEncoder().encode(report)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["overallStatus"] as? String, "fail")
    }

    /// Text output is what a CI log or terminal actually shows; it must
    /// name every check and its status in a stable, greppable shape.
    func testTextReportListsEveryCheckIDAndStatus() {
        let report = LumaHarborDiagnosticsRunner.run(environment: [:])
        let text = report.textReport()
        for check in report.checks {
            XCTAssertTrue(text.contains(check.id), "text report must mention check id \(check.id)")
            XCTAssertTrue(text.contains(check.status.rawValue.uppercased()), "text report must mention \(check.id)'s status")
        }
    }

    // MARK: - Never reports PASS for zero executed checks (roadmap's own requirement)

    func testReportNeverClaimsOverallPassWithZeroChecks() {
        let emptyReport = DiagnosticsReport(checks: [])
        XCTAssertFalse(emptyReport.passed, "an empty report must never claim to have passed")
    }
}
