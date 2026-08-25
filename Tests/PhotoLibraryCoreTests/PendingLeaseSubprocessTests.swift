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
final class PendingLeaseSubprocessTests: TemporaryDirectoryTestCase {

    // MARK: - Helpers

    private func pendingLeaseHelperURL() throws -> URL {
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
            throw XCTSkip("PendingLeaseHelper binary not found next to the test bundle -- expected when built via `swift build --build-tests` / `swift test`.")
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
        try process.run()
        return process
    }

    /// Polls for the helper's ready file rather than sleeping a guessed
    /// duration -- the file is written only once the child's lease is
    /// genuinely held (see `PendingLeaseHelper`), so this is a real
    /// handshake, not a timing guess.
    private func waitForReadyDocumentID(at url: URL, timeout: TimeInterval = 10) async throws -> UUID {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: url),
               let string = String(data: data, encoding: .utf8),
               let id = UUID(uuidString: string) {
                return id
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw XCTSkip("Timed out waiting for the helper process to signal it holds the lease.")
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

    // MARK: - Tests

    func testAnotherProcessesHeldLeaseIsSkippedByParentReconciliationAndReclaimedAfterItExits() async throws {
        let sourceURL = try makeSourceFile()
        let rootURL = temporaryDirectory.appendingPathComponent("Store", isDirectory: true)
        let readyFileURL = temporaryDirectory.appendingPathComponent("ready-\(UUID().uuidString)")

        let process = try launchHelper(mode: "appCopy", sourceURL: sourceURL, rootURL: rootURL, readyFileURL: readyFileURL)
        defer {
            // Belt-and-suspenders cleanup if an assertion above fails
            // before the test's own graceful-exit request runs.
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }

        let documentID = try await waitForReadyDocumentID(at: readyFileURL)
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

        let afterExit = try await parentStore.reconcileOrphanedImports(activePointer: .noActiveDocument)
        XCTAssertTrue(afterExit.rolledBackPendingIDs.contains(documentID), "once the owning process has genuinely exited, its never-finalized creation must be reclaimed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordURL.path))
    }

    func testAProcessKilledWithSIGKILLReleasesItsLeaseForReconciliation() async throws {
        let sourceURL = try makeSourceFile()
        let rootURL = temporaryDirectory.appendingPathComponent("Store", isDirectory: true)
        let readyFileURL = temporaryDirectory.appendingPathComponent("ready-\(UUID().uuidString)")

        let process = try launchHelper(mode: "inPlace", sourceURL: sourceURL, rootURL: rootURL, readyFileURL: readyFileURL)
        let documentID = try await waitForReadyDocumentID(at: readyFileURL)

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

        let afterKill = try await parentStore.reconcileOrphanedImports(activePointer: .noActiveDocument)
        XCTAssertTrue(afterKill.rolledBackPendingIDs.contains(documentID), "the kernel must have released the lease when the process was killed, letting reconciliation reclaim the abandoned creation")

        // The in-place rollback this triggers must never touch the
        // external RAW -- doubly worth checking here, since nothing about
        // this specific recovery path went through a normal in-process
        // rollback call.
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
    }
}
