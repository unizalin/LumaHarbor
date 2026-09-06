import Foundation

/// Roadmap Phase 5 Task 5.5: headless diagnostics. A check's own outcome --
/// deliberately four states, not a boolean, so "we didn't run this" (no
/// fixture configured) is never confused with either "it's fine" or "it's
/// broken" (design spec §8.3's "failed / skipped / not run 不得偽裝成
/// 成功", the same principle behind `BatchExportItemStatus`).
public enum DiagnosticStatus: String, Equatable, Codable, Sendable {
    case pass
    case warning
    case fail
    case skipped
}

/// One diagnostic check's result. `message`/`title`/`remediation` must
/// never contain a real filesystem path -- see `LumaHarborDiagnosticsRunner`'s
/// own doc comment on why, and `LumaHarborDiagnosticsRunnerTests` for the
/// tests that hold this to account.
public struct DiagnosticCheck: Equatable, Codable, Sendable {
    /// Stable, dotted identifier (e.g. `"localization.eightLanguages"`) --
    /// safe to grep for in CI logs and never renamed across releases once
    /// shipped, the same contract `LumaHarborDiagnosticsRunner
    /// .expectedCheckIDs` documents.
    public var id: String
    public var title: String
    public var message: String
    public var status: DiagnosticStatus
    /// What to do about it, when `status` is `.warning` or `.fail`. `nil`
    /// for a plain `.pass`/`.skipped` with nothing actionable to suggest.
    public var remediation: String?

    public init(id: String, title: String, message: String, status: DiagnosticStatus, remediation: String? = nil) {
        self.id = id
        self.title = title
        self.message = message
        self.status = status
        self.remediation = remediation
    }
}

/// The full result of one `LumaHarborDiagnosticsRunner.run(environment:)`
/// call.
public struct DiagnosticsReport: Equatable, Codable, Sendable {
    public var checks: [DiagnosticCheck]

    public init(checks: [DiagnosticCheck]) {
        self.checks = checks
    }

    /// `false` whenever any check is `.fail`, and *also* `false` for an
    /// empty report -- a run that executed zero checks must never claim to
    /// have passed (roadmap's own "do not report PASS for zero executed
    /// tests" requirement for this task, carried over from the `selftest`/
    /// `exporttest` scripts it names).
    public var passed: Bool {
        !checks.isEmpty && !checks.contains { $0.status == .fail }
    }

    public func count(_ status: DiagnosticStatus) -> Int {
        checks.filter { $0.status == status }.count
    }

    /// Stable-shape machine-readable output (one JSON object per line-free
    /// document, pretty-printed for a human reading it in a terminal too).
    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
    }

    /// Plain-text contract: one line per check, `id: STATUS -- message`,
    /// then a trailing summary line -- mirrors `Scripts/run-mvp-
    /// acceptance.zsh`'s own `label: STATE (detail)` convention rather than
    /// inventing a second text format for the same kind of report.
    public func textReport() -> String {
        var lines: [String] = []
        for check in checks {
            var line = "\(check.id): \(check.status.rawValue.uppercased()) -- \(check.message)"
            if let remediation = check.remediation {
                line += " (\(remediation))"
            }
            lines.append(line)
        }
        lines.append(
            "SUMMARY: \(count(.pass)) pass, \(count(.warning)) warning, "
            + "\(count(.fail)) fail, \(count(.skipped)) skipped -- overall \(passed ? "PASS" : "FAIL")"
        )
        return lines.joined(separator: "\n")
    }
}
