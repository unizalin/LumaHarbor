import Foundation
import XCTest
@testable import EditorCore
import PhotoLibraryCore
import RawProcessingCore

private struct SaveRacePreviewRenderer: PreviewRendering {
    func render(_ request: PreviewRequest) async throws -> PreviewImage {
        throw CancellationError()
    }
}

private actor SaveRaceGate {
    private var continuations: [Int: CheckedContinuation<Void, Error>] = [:]
    private var requests: [PhotoAdjustments] = []

    func save(_ adjustments: PhotoAdjustments) async throws {
        let index = requests.count
        requests.append(adjustments)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            continuations[index] = continuation
        }
    }

    func requestCount() -> Int { requests.count }

    func release(_ index: Int) {
        continuations.removeValue(forKey: index)?.resume()
    }

    func fail(_ index: Int) {
        continuations.removeValue(forKey: index)?.resume(throwing: SaveRaceError.failed)
    }
}

private enum SaveRaceError: Error {
    case failed
}

@MainActor
final class EditorSessionSaveRaceTests: XCTestCase {
    private func makeEditor(
        gate: SaveRaceGate,
        onSaved: @escaping (PhotoID, Bool) -> Void
    ) -> EditorSession {
        let editor = EditorSession()
        let renderer = SaveRacePreviewRenderer()
        editor.attach(dependencies: EditorDependencies(
            previewScheduler: PreviewScheduler(renderer: renderer),
            previewRenderer: renderer,
            loadAdjustments: { _ in .neutral },
            saveAdjustments: { adjustments, _ in try await gate.save(adjustments) }
        ))
        editor.onSaved = onSaved
        editor.open(
            photo: PhotoAsset(
                id: PhotoID(), libraryID: LibraryID(), relativePath: "fixture.ARW",
                fingerprint: FileFingerprint(fileSize: 4, edgeDigest: "fixture"), status: .ready
            ),
            sourceURL: URL(fileURLWithPath: "/fixture.ARW"),
            adjustments: .neutral,
            isReadOnly: false
        )
        return editor
    }

    private func waitForRequests(_ gate: SaveRaceGate, _ count: Int) async throws {
        for _ in 0..<200 {
            if await gate.requestCount() >= count { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("timed out waiting for save request (count)")
    }

    func testOutOfOrderSavesCannotOverwriteLatestContentOrSavedCallback() async throws {
        var callbacks: [(PhotoID, Bool)] = []
        let gate = SaveRaceGate()
        let editor = makeEditor(gate: gate) { photoID, hasEdits in
            callbacks.append((photoID, hasEdits))
        }

        editor.setAdjustment(.exposure, to: 1)
        let saveA = Task { await editor.save() }
        try await waitForRequests(gate, 1)

        editor.setAdjustment(.exposure, to: 2)
        let saveB = Task { await editor.save() }
        try await waitForRequests(gate, 2)

        editor.setAdjustment(.exposure, to: 3)
        let saveC = Task { await editor.save() }
        try await waitForRequests(gate, 3)

        // Completion order is deliberately newer-to-older.  A, B and C all
        // started from a dirty state; only C still describes the current edit.
        await gate.release(2)
        await saveC.value
        await gate.release(1)
        await saveB.value
        await gate.release(0)
        await saveA.value

        XCTAssertEqual(editor.adjustments.exposure, 3)
        guard case .saved = editor.saveState else {
            return XCTFail("latest save should remain saved, got \(editor.saveState)")
        }
        XCTAssertEqual(callbacks.count, 1)
        XCTAssertEqual(callbacks.first?.1, true)

        // If stale B had overwritten lastSavedAdjustments, undoing C would be
        // reported clean.  It must remain dirty because C is the disk value.
        editor.undo()
        XCTAssertEqual(editor.adjustments.exposure, 2)
        XCTAssertEqual(editor.saveState, .pending)
    }

    func testEditingDuringSaveWithoutResavingRemainsPendingAndDoesNotCallSaved() async throws {
        var callbackCount = 0
        let gate = SaveRaceGate()
        let editor = makeEditor(gate: gate) { _, _ in callbackCount += 1 }

        editor.setAdjustment(.exposure, to: 1)
        let save = Task { await editor.save() }
        try await waitForRequests(gate, 1)

        editor.setAdjustment(.exposure, to: 2)
        await gate.release(0)
        await save.value

        XCTAssertEqual(editor.adjustments.exposure, 2)
        XCTAssertEqual(editor.saveState, .pending)
        XCTAssertEqual(callbackCount, 0)
    }

    func testOlderFailureCannotOverwriteNewerSuccessOrDirtyState() async throws {
        var callbacks: [(PhotoID, Bool)] = []
        let gate = SaveRaceGate()
        let editor = makeEditor(gate: gate) { photoID, hasEdits in
            callbacks.append((photoID, hasEdits))
        }

        editor.setAdjustment(.exposure, to: 1)
        let saveA = Task { await editor.save() }
        try await waitForRequests(gate, 1)

        editor.setAdjustment(.exposure, to: 2)
        let saveB = Task { await editor.save() }
        try await waitForRequests(gate, 2)

        await gate.release(1)
        await saveB.value
        await gate.fail(0)
        await saveA.value

        XCTAssertEqual(editor.adjustments.exposure, 2)
        guard case .saved = editor.saveState else {
            return XCTFail("newer successful save should remain saved, got \(editor.saveState)")
        }
        XCTAssertEqual(callbacks.count, 1)
    }

    func testOlderFailureLeavesNewerUnsavedEditPending() async throws {
        var callbackCount = 0
        let gate = SaveRaceGate()
        let editor = makeEditor(gate: gate) { _, _ in callbackCount += 1 }

        editor.setAdjustment(.exposure, to: 1)
        let save = Task { await editor.save() }
        try await waitForRequests(gate, 1)

        editor.setAdjustment(.exposure, to: 2)
        await gate.fail(0)
        await save.value

        XCTAssertEqual(editor.adjustments.exposure, 2)
        XCTAssertEqual(editor.saveState, .pending)
        XCTAssertEqual(callbackCount, 0)
    }
}
