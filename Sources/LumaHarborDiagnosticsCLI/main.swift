import Foundation
import LumaHarborApp

/// Headless diagnostics entry point (roadmap Phase 5 Task 5.5). Runs
/// `LumaHarborDiagnosticsRunner` -- the same runner
/// `LumaHarborDiagnosticsRunnerTests` exercises directly in-process -- and
/// prints its report. No window, no `NSApplication`, no fixture required
/// beyond the three optional `LUMAHARBOR_*` environment variables the
/// runner itself already checks for.
///
/// Usage:
///     swift run LumaHarborDiagnosticsCLI              # text report
///     swift run LumaHarborDiagnosticsCLI --json        # JSON report
///
/// Exit code is 0 when every check passed (or was skipped/warned), 1 when
/// any check failed -- so this can gate a CI step without parsing output.
let arguments = CommandLine.arguments.dropFirst()
let wantsJSON = arguments.contains("--json")

let report = LumaHarborDiagnosticsRunner.run()

if wantsJSON {
    do {
        print(try report.jsonString())
    } catch {
        FileHandle.standardError.write(Data("failed to encode diagnostics report as JSON: \(error)\n".utf8))
        exit(2)
    }
} else {
    print(report.textReport())
}

exit(report.passed ? 0 : 1)
