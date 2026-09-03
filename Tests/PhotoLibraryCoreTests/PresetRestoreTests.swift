import XCTest
@testable import PhotoLibraryCore
@testable import PresetCore

/// Phase 3 Task 3.2: "Add restore conflict tests." `restorePresets(_:into:conflict:)`
/// replays every document from a `PresetBackupArchive` into a real
/// `PresetRepository` and reports what actually happened per document --
/// tested against `FilePresetRepository` (not a mock) specifically because
/// the mock repository used elsewhere in this codebase
/// (`RecordingPresetRepository`, `LumaHarborAppTests`) always reports
/// `.created` regardless of `conflict` or existing content, which would
/// never actually exercise a conflict.
final class PresetRestoreTests: TemporaryDirectoryTestCase {
    private var presetsRoot: URL!
    private var repository: FilePresetRepository!

    override func setUpWithError() throws {
        try super.setUpWithError()
        presetsRoot = try makeSubdirectory("Presets")
        repository = FilePresetRepository(scope: .myPresets(rootURL: presetsRoot))
    }

    private func makePreset(id: UUID = UUID(), name: String = "Golden Hour", exposure: Double = 0.5) -> PresetDocument {
        PresetDocument(id: id, name: name, patch: AdjustmentPatch(basic: BasicAdjustmentPatch(exposure: exposure)))
    }

    func testRestoringIntoAnEmptyRepositoryCreatesEveryDocument() async throws {
        let documents = [makePreset(name: "A"), makePreset(name: "B")]

        let summary = await restorePresets(documents, into: repository, conflict: .replace)

        XCTAssertEqual(summary.created, 2)
        XCTAssertEqual(summary.replaced, 0)
        XCTAssertEqual(summary.keptBoth, 0)
        XCTAssertEqual(summary.duplicateSkipped, 0)
        XCTAssertEqual(summary.cancelled, 0)
        XCTAssertEqual(summary.failed, 0)
        let listed = try await repository.list()
        XCTAssertEqual(listed.count, 2)
    }

    func testRestoringTheSameCanonicalContentTwiceIsSkippedNotDuplicated() async throws {
        let preset = makePreset()
        _ = await restorePresets([preset], into: repository, conflict: .replace)

        let summary = await restorePresets([preset], into: repository, conflict: .replace)

        XCTAssertEqual(summary.duplicateSkipped, 1)
        XCTAssertEqual(summary.created, 0)
        let listed = try await repository.list()
        XCTAssertEqual(listed.count, 1, "Restoring an identical backup twice must not double the library")
    }

    func testRestoringConflictingContentWithReplacePolicyOverwritesInPlace() async throws {
        let id = UUID()
        _ = await restorePresets([makePreset(id: id, exposure: 0.5)], into: repository, conflict: .replace)

        let summary = await restorePresets([makePreset(id: id, exposure: 1.5)], into: repository, conflict: .replace)

        XCTAssertEqual(summary.replaced, 1)
        let loaded = try await repository.load(id: id)
        XCTAssertEqual(loaded?.patch.basic?.exposure, 1.5)
        let listed = try await repository.list()
        XCTAssertEqual(listed.count, 1)
    }

    func testRestoringConflictingContentWithKeepBothPolicyMintsNewIdentitiesAndKeepsTheOriginal() async throws {
        let id = UUID()
        _ = await restorePresets([makePreset(id: id, exposure: 0.5)], into: repository, conflict: .replace)

        let summary = await restorePresets([makePreset(id: id, exposure: 1.5)], into: repository, conflict: .keepBoth)

        XCTAssertEqual(summary.keptBoth, 1)
        let listed = try await repository.list()
        XCTAssertEqual(listed.count, 2)
        let originalStillThere = try await repository.load(id: id)
        XCTAssertEqual(originalStillThere?.patch.basic?.exposure, 0.5, "keepBoth must never touch what was already there")
    }

    func testRestoringConflictingContentWithCancelPolicyWritesNothing() async throws {
        let id = UUID()
        _ = await restorePresets([makePreset(id: id, exposure: 0.5)], into: repository, conflict: .replace)

        let summary = await restorePresets([makePreset(id: id, exposure: 1.5)], into: repository, conflict: .cancel)

        XCTAssertEqual(summary.cancelled, 1)
        let listed = try await repository.list()
        XCTAssertEqual(listed.count, 1)
        let stillOriginal = try await repository.load(id: id)
        XCTAssertEqual(stillOriginal?.patch.basic?.exposure, 0.5)
    }

    func testAnInvalidDocumentInTheMiddleIsCountedFailedButOthersStillRestore() async throws {
        let good1 = makePreset(name: "Good 1")
        let invalid = PresetDocument(name: "   ", patch: AdjustmentPatch(basic: BasicAdjustmentPatch(exposure: 0)))
        let good2 = makePreset(name: "Good 2")

        let summary = await restorePresets([good1, invalid, good2], into: repository, conflict: .replace)

        XCTAssertEqual(summary.created, 2)
        XCTAssertEqual(summary.failed, 1)
        let listed = try await repository.list()
        XCTAssertEqual(listed.count, 2)
    }

    func testRestoringIntoAReadOnlyDestinationCountsEveryDocumentFailed() async throws {
        // `BuiltInPresetRepository` always throws `builtInPresetIsReadOnly`
        // from `save` -- restore must surface that as `.failed` per document,
        // never crash or silently drop the whole batch.
        let readOnly = BuiltInPresetRepository(documents: [])
        let summary = await restorePresets([makePreset(), makePreset()], into: readOnly, conflict: .replace)
        XCTAssertEqual(summary.failed, 2)
        XCTAssertEqual(summary.created, 0)
    }
}
