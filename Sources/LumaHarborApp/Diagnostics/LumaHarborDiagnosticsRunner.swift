import Foundation
import Localization
import RawProcessingCore

/// Headless diagnostics (roadmap Phase 5 Task 5.5; design spec §12.2's
/// "diagnostic commands need to match AwayPhotoRawEditor's headless
/// spirit"). Every check here is a plain, synchronous function over
/// in-process state -- no window, no `NSApplication`, no person at a
/// keyboard, and (aside from the three optional fixture directories) no
/// real device or camera file.
///
/// Deliberately narrower than the roadmap's own `selftest`/`exporttest`/
/// `shot`/`gallery` four-command list: `shot` (open the fixture library and
/// screenshot the UI) and `gallery` (thumbnail/preview regression evidence)
/// both need a real window and real fixture photos on screen, which is the
/// opposite of "headless" -- this round's own instruction is to build the
/// gate/tooling/tests for what *can* run with no GUI and no fixtures, and
/// to document the rest as a known gap rather than fake it. See
/// `docs/coordination/CURRENT.md`'s Phase 5 Task 5.5 entry.
///
/// Every message/title/remediation string here is developer/CI-facing
/// (plain English, not routed through `L10n.t`), matching the existing
/// `Scripts/run-mvp-acceptance.zsh` convention this mirrors -- it is not
/// end-user UI text.
public enum LumaHarborDiagnosticsRunner {
    /// The full, stable set of check IDs a report always contains, in the
    /// order `run(environment:)` produces them. Never remove or repurpose
    /// an ID once shipped; add a new one instead.
    public static let expectedCheckIDs: [String] = [
        "localization.eightLanguages",
        "theme.preference",
        "export.formatsCapability",
        "batchExport.queueCapability",
        "fixture.rawDirectory",
        "fixture.apfsTestDirectory",
        "fixture.exfatTestDirectory",
    ]

    /// The eight languages roadmap Task 5.4 (and this task's own
    /// documentation) name -- see `EightLanguageLocalizationGateTests` for
    /// the full-coverage test suite this check summarizes at a glance.
    private static let requiredLanguageCodes = ["zh-Hant", "en", "ja", "ko", "zh-Hans", "de", "fr", "es"]

    /// `environment` is injectable (defaults to the real process
    /// environment) so tests can simulate "fixture configured" / "fixture
    /// missing" without touching the actual process's environment, which
    /// Swift has no supported way to mutate at runtime anyway.
    public static func run(environment: [String: String] = ProcessInfo.processInfo.environment) -> DiagnosticsReport {
        DiagnosticsReport(checks: [
            localizationCheck(),
            themePreferenceCheck(),
            exportFormatsCheck(),
            batchExportQueueCheck(),
            fixtureDirectoryCheck(
                id: "fixture.rawDirectory",
                title: "RAW fixture directory",
                environmentKey: "LUMAHARBOR_RAW_FIXTURE_DIR",
                environment: environment
            ),
            fixtureDirectoryCheck(
                id: "fixture.apfsTestDirectory",
                title: "APFS scratch test directory",
                environmentKey: "LUMAHARBOR_APFS_TEST_DIR",
                environment: environment
            ),
            fixtureDirectoryCheck(
                id: "fixture.exfatTestDirectory",
                title: "exFAT scratch test directory",
                environmentKey: "LUMAHARBOR_EXFAT_TEST_DIR",
                environment: environment
            ),
        ])
    }

    // MARK: - Localization

    private static func localizationCheck() -> DiagnosticCheck {
        var missing: [String] = []
        var unreadable: [String] = []
        for code in requiredLanguageCodes {
            guard let count = L10n.keyCount(for: code) else {
                missing.append(code)
                continue
            }
            if count == 0 {
                unreadable.append(code)
            }
        }

        if missing.isEmpty, unreadable.isEmpty {
            return DiagnosticCheck(
                id: "localization.eightLanguages",
                title: "Eight-language resource coverage",
                message: "all \(requiredLanguageCodes.count) required languages ship a readable Localizable.strings",
                status: .pass
            )
        }
        var problems: [String] = []
        if !missing.isEmpty { problems.append("missing: \(missing.joined(separator: ", "))") }
        if !unreadable.isEmpty { problems.append("empty/unreadable: \(unreadable.joined(separator: ", "))") }
        return DiagnosticCheck(
            id: "localization.eightLanguages",
            title: "Eight-language resource coverage",
            message: problems.joined(separator: "; "),
            status: .fail,
            remediation: "see EightLanguageLocalizationGateTests for the full per-key coverage gate"
        )
    }

    // MARK: - Theme

    /// Proves `AppTheme` itself is internally consistent (default is
    /// `.system`, every raw value round-trips) and that whatever is
    /// actually persisted under the app's own `UserDefaults` key -- if
    /// anything -- still parses. A missing stored value is not a problem
    /// (the app has never been run, or the user never changed it): it just
    /// means `AppTheme.default` applies, same as `RootView`'s own
    /// `@AppStorage` default.
    private static func themePreferenceCheck() -> DiagnosticCheck {
        guard AppTheme.default == .system,
              AppTheme.allCases.allSatisfy({ AppTheme(rawValue: $0.rawValue) == $0 }) else {
            return DiagnosticCheck(
                id: "theme.preference",
                title: "Theme preference model",
                message: "AppTheme's default or raw-value round-trip is broken",
                status: .fail
            )
        }

        let storedRawValue = UserDefaults.standard.string(forKey: "appTheme")
        guard let storedRawValue else {
            return DiagnosticCheck(
                id: "theme.preference",
                title: "Theme preference model",
                message: "no stored preference yet; default (\(AppTheme.default.rawValue)) applies",
                status: .pass
            )
        }
        if AppTheme(rawValue: storedRawValue) != nil {
            return DiagnosticCheck(
                id: "theme.preference",
                title: "Theme preference model",
                message: "stored preference parses",
                status: .pass
            )
        }
        return DiagnosticCheck(
            id: "theme.preference",
            title: "Theme preference model",
            message: "a stored \"appTheme\" value exists but doesn't match any AppTheme case; the app falls back to the default rather than crashing",
            status: .warning,
            remediation: "clear the \"appTheme\" key in UserDefaults if this persists"
        )
    }

    // MARK: - Export

    private static func exportFormatsCheck() -> DiagnosticCheck {
        let formats = ExportFormat.allCases
        let wellFormed = !formats.isEmpty && formats.allSatisfy { !$0.displayName.isEmpty && !$0.fileExtension.isEmpty }
        guard wellFormed else {
            return DiagnosticCheck(
                id: "export.formatsCapability",
                title: "Export format capability table",
                message: "one or more ExportFormat cases has an empty display name or file extension",
                status: .fail
            )
        }

        let encodable = ExportFormat.systemEncodableTypeIdentifiers()
        let supportedCount = formats.filter { $0.isSupported(by: encodable) }.count
        return DiagnosticCheck(
            id: "export.formatsCapability",
            title: "Export format capability table",
            message: "\(formats.count) formats defined, \(supportedCount) encodable on this build",
            status: .pass
        )
    }

    // MARK: - Batch export

    /// "Capability can be constructed", per this round's own scope --
    /// proves `BatchExportQueue`'s default initializer (the same one
    /// `LibraryViewModel.batchExportQueue`'s own property default uses)
    /// doesn't throw or crash. Running an actual export needs a real RAW
    /// source and destination directory, which is `fixture.rawDirectory`'s
    /// job, not this one's.
    private static func batchExportQueueCheck() -> DiagnosticCheck {
        _ = BatchExportQueue()
        return DiagnosticCheck(
            id: "batchExport.queueCapability",
            title: "Batch export queue capability",
            message: "BatchExportQueue constructs with its default PhotoExporter",
            status: .pass
        )
    }

    // MARK: - Fixture directories

    /// Never includes the directory's own path or basename in any field --
    /// only the fixed environment variable *name* and a boolean-shaped
    /// outcome. `LumaHarborDiagnosticsRunnerTests` asserts this directly
    /// against both a nonexistent and a real (test-created) directory.
    private static func fixtureDirectoryCheck(
        id: String,
        title: String,
        environmentKey: String,
        environment: [String: String]
    ) -> DiagnosticCheck {
        guard let path = environment[environmentKey], !path.isEmpty else {
            return DiagnosticCheck(
                id: id,
                title: title,
                message: "\(environmentKey) is not set",
                status: .skipped,
                remediation: "set \(environmentKey) to run this check; see Scripts/run-mvp-acceptance.zsh for the same convention"
            )
        }

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue else {
            return DiagnosticCheck(
                id: id,
                title: title,
                message: "\(environmentKey) is set but does not point at an existing directory",
                status: .warning,
                remediation: "check the \(environmentKey) value locally; this diagnostic never prints it"
            )
        }
        return DiagnosticCheck(
            id: id,
            title: title,
            message: "\(environmentKey) is set and points at an existing directory",
            status: .pass
        )
    }
}
