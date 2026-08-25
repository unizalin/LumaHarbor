import Darwin
import Foundation
import XCTest
@testable import PhotoLibraryCore

/// Proves `PendingLock` (the per-document pending-creation lease) actually
/// contends across *separate processes*, not merely two `PhotoDocumentStore`
/// instances sharing one PID — which two-instances-in-one-process tests
/// elsewhere in `PhotoDocumentStoreTests` cannot demonstrate, since they
/// never leave the parent's process table at all. Each test here launches
/// `PendingLeaseHelper` (a small standalone executable — see
/// `Sources/PendingLeaseHelper/main.swift`) as a genuine child process that
/// acquires and holds a lease, then proves the parent's own
/// `reconcileOrphanedImports` skips it while the child is alive and can
/// reclaim it once the child is actually gone — whether by a graceful
/// exit or a `SIGKILL` the child gets no chance to react to.
///
/// No fixed `sleep` anywhere: readiness is a file the child writes only
/// after the lease is genuinely held (polled for, not slept for), and
/// "gone" is `Process.waitUntilExit()` — a real, blocking wait on the
/// child's actual termination, not a guessed duration.
///
/// This durability gate must never go quiet: both the helper binary being
/// missing and the child failing to signal readiness within the timeout
/// fail the test (`XCTFail` + a thrown error), not `XCTSkip` — a build
/// that silently stops producing `PendingLeaseHelper`, or a real
/// regression that hangs the handshake, must show up as a failing test,
/// not a skipped one nobody notices.
final class PendingLeaseSubprocessTests: TemporaryDirectoryTestCase {

    private struct SetupFailure: Error {}

    // MARK: - Helpers

    private func pendingLeaseHelperURL(file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        // `swift test` runs this test's code *inside* the
        // `LumaHarborPackageTests.xctest` bundle, loaded by a generic
        // `xctest` runner -- `CommandLine.arguments[0]` is that runner's
        // own path, not this bundle's, so it can't be used to find a
        // sibling build product. `Bundle(for:)` gives the `.xctest`
        // bundle itself instead; every target's build product (including
        // this test-support-only executable) lands in the same directory
        // one level up from it.
        let testBundleURL = Bundle(for: PendingLeaseSubprocessTests.self).bundleURL
        let directory = testBundleURL.deletingLastPathComponent()
        let candidate = directory.appendingPathComponent("PendingLeaseHelper")
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            XCTFail(
                "PendingLeaseHelper binary not found next to the test bundle. "
                    + "This is a required cross-process durability gate -- it must fail loudly, "
                    + "not be silently skipped. Rebuild via `swift build --build-tests` / `swift test`.",
                file: file, line: line
            )
            throw SetupFailure()
        }
        return candidate
    }

    private func makeSourceFile(named name: String = "fixture.ARW") throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name)
        try Data(repeating: 0x42, count: 4_096).write(to: url)
        return url
    }

    @discardableResult
    private func launchHelper(mode: String, sourceURL: URL, rootURL: URL, readyFileURL: URL) throws -> Process {
        let process = Process()
        process.executableURL = try pendingLeaseHelperURL()
        process.arguments = [rootURL.path, mode, sourceURL.path, readyFileURL.path]
        process.standardInput = Pipe()
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        try process.run()
        return process
    }

    /// Reads whatever the helper has written to stderr so far and redacts
    /// anything that looks like an absolute path before it's ever put into
    /// an assertion message -- a diagnostic aid must not itself become the
    /// thing leaking a private path.
    private func sanitizedStandardError(of process: Process) -> String {
        guard let pipe = process.standardError as? Pipe else { return "<no stderr captured>" }
        let data = pipe.fileHandleForReading.availableData
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return "<empty>"
        }
        var redacted = text
        redacted = redacted.replacingOccurrences(of: temporaryDirectory.path, with: "<tmp>")
        for prefix in ["/Users/", "/Volumes/", "/private/var/", "/private/tmp/"] {
            while let range = redacted.range(of: prefix) {
                let pathEnd = redacted[range.upperBound...].firstIndex(where: { $0.isWhitespace || $0 == "\"" || $0 == "'" })
                    ?? redacted.endIndex
                redacted.replaceSubrange(range.lowerBound..<pathEnd, with: "<redacted-path>")
            }
        }
        return redacted
    }

    /// Polls for the helper's ready file rather than sleeping a guessed
    /// duration -- the file is written only once the child's lease is
    /// genuinely held (see `PendingLeaseHelper`), so this is a real
    /// handshake, not a timing guess. A timeout here means the durability
    /// gate itself is broken (or the helper crashed before signaling) and
    /// must fail the test loudly, with enough to diagnose why: whether
    /// the process is still running, its exit status if not, and its
    /// sanitized stderr.
    private func waitForReadyDocumentID(
        at url: URL, helper process: Process, timeout: TimeInterval = 10,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws -> UUID {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: url),
               let string = String(data: data, encoding: .utf8),
               let id = UUID(uuidString: string) {
                return id
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        let stillRunning = process.isRunning
        let statusDescription = stillRunning
            ? "still running (pid \(process.processIdentifier))"
            : "exited with status \(process.terminationStatus), reason \(process.terminationReason.rawValue)"
        XCTFail(
            "Timed out waiting for PendingLeaseHelper to signal it holds the lease. "
                + "Helper process is \(statusDescription). stderr: \(sanitizedStandardError(of: process))",
            file: file, line: line
        )
        if stillRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        throw SetupFailure()
    }

    /// Tells the child (still blocked on `readLine()`) to exit gracefully,
    /// then blocks -- for real, via the OS -- until it actually has.
    private func requestGracefulExit(of process: Process) {
        if let stdin = process.standardInput as? Pipe {
            stdin.fileHandleForWriting.write(Data("done\n".utf8))
            try? stdin.fileHandleForWriting.close()
        }
        process.waitUntilExit()
    }

    /// Unconditional cleanup for a `defer` right after a helper process is
    /// launched: if it's still running for any reason (an assertion above
    /// failed and unwound the test, the graceful-exit request was never
    /// reached, etc.), it is killed and *actually* waited for -- never
    /// left as a lingering subprocess just because the test that started
    /// it ended early.
    private func forceCleanup(_ process: Process) {
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    /// Directly probes whether `documentID`'s per-document lease is free
    /// right now, the same way `PendingLock`/`RootImportLock` themselves
    /// do -- independent of what `reconcileOrphanedImports` decides to do
    /// with that fact, so a lease genuinely being released is verified as
    /// its own, separate claim rather than only inferred from
    /// reconciliation's behavior.
    private func isLeaseFree(rootURL: URL, documentID: UUID) -> Bool {
        let lockURL = rootURL
            .appendingPathComponent("PendingLocks", isDirectory: true)
            .appendingPathComponent("\(documentID.uuidString).lock")
        let fileDescriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard fileDescriptor >= 0 else { return false }
        defer { close(fileDescriptor) }
        guard flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 else { return false }
        flock(fileDescriptor, LOCK_UN)
        return true
    }

    // MARK: - Tests

    func testAnotherProcessesHeldLeaseIsSkippedByParentReconciliationAndReclaimedAfterItExits() async throws {
        let sourceURL = try makeSourceFile()
        let rootURL = temporaryDirectory.appendingPathComponent("Store", isDirectory: true)
        let readyFileURL = temporaryDirectory.appendingPathComponent("ready-\(UUID().uuidString)")

        let process = try launchHelper(mode: "appCopy", sourceURL: sourceURL, rootURL: rootURL, readyFileURL: readyFileURL)
        defer { forceCleanup(process) }

        let documentID = try await waitForReadyDocumentID(at: readyFileURL, helper: process)
        XCTAssertFalse(isLeaseFree(rootURL: rootURL, documentID: documentID), "the child must genuinely hold the lease by the time it signals ready")
        let recordURL = rootURL.appendingPathComponent("Records").appendingPathComponent("\(documentID.uuidString).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordURL.path), "the child's pending record must already be on disk by the time it signals ready")

        let parentStore = PhotoDocumentStore(rootURL: rootURL)
        let whileAlive = try await parentStore.reconcileOrphanedImports(activePointer: .noActiveDocument)
        XCTAssertFalse(whileAlive.rolledBackPendingIDs.contains(documentID), "a lease genuinely held by a separate, still-running process must never be touched")
        XCTAssertTrue(whileAlive.failures.isEmpty, "a held-elsewhere lease is not a failure -- it is correctly and quietly skipped")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordURL.path), "still there -- untouched while the child is alive")

        requestGracefulExit(of: process)
        XCTAssertFalse(process.isRunning, "the child must have genuinely exited before reconciliation is asked to reclaim its lease")
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(isLeaseFree(rootURL: rootURL, documentID: documentID), "the lease must be free the moment the holding process is actually gone")

        let afterExit = try await parentStore.reconcileOrphanedImports(activePointer: .noActiveDocument)
        XCTAssertTrue(afterExit.rolledBackPendingIDs.contains(documentID), "once the owning process has genuinely exited, its never-finalized creation must be reclaimed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordURL.path))
    }

    func testAProcessKilledWithSIGKILLReleasesItsLeaseForReconciliation() async throws {
        let sourceURL = try makeSourceFile()
        let rootURL = temporaryDirectory.appendingPathComponent("Store", isDirectory: true)
        let readyFileURL = temporaryDirectory.appendingPathComponent("ready-\(UUID().uuidString)")

        let process = try launchHelper(mode: "inPlace", sourceURL: sourceURL, rootURL: rootURL, readyFileURL: readyFileURL)
        // Installed immediately after a successful launch -- before
        // `waitForReadyDocumentID` (which can itself fail/throw) or any
        // assertion below gets a chance to leave this child running.
        defer { forceCleanup(process) }

        let documentID = try await waitForReadyDocumentID(at: readyFileURL, helper: process)
        XCTAssertFalse(isLeaseFree(rootURL: rootURL, documentID: documentID))

        let parentStore = PhotoDocumentStore(rootURL: rootURL)
        let whileAlive = try await parentStore.reconcileOrphanedImports(activePointer: .noActiveDocument)
        XCTAssertFalse(whileAlive.rolledBackPendingIDs.contains(documentID))

        // No cooperation from the child at all here -- exactly what a real
        // crash looks like. The kernel, not this code, is what releases
        // the flock.
        XCTAssertEqual(kill(process.processIdentifier, SIGKILL), 0, "failed to signal the helper process")
        process.waitUntilExit()
        XCTAssertFalse(process.isRunning, "the child must have genuinely terminated, not merely be assumed to -- no lingering subprocess left behind")
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertTrue(isLeaseFree(rootURL: rootURL, documentID: documentID), "the kernel must have released the lease the moment the killed process was reaped")

        let afterKill = try await parentStore.reconcileOrphanedImports(activePointer: .noActiveDocument)
        XCTAssertTrue(afterKill.rolledBackPendingIDs.contains(documentID), "the kernel must have released the lease when the process was killed, letting reconciliation reclaim the abandoned creation")

        // The in-place rollback this triggers must never touch the
        // external RAW -- doubly worth checking here, since nothing about
        // this specific recovery path went through a normal in-process
        // rollback call.
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
    }
}
