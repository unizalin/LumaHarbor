import XCTest
@testable import PhotoLibraryCore
@testable import PresetCore

/// Spec §8.1/§8.2: two independent storage scopes, atomic file writes, UUID
/// identity (never filename or display name), and explicit conflict handling
/// rather than silent overwrite.
final class PresetRepositoryTests: TemporaryDirectoryTestCase {
    private var presetsRoot: URL!
    private var repository: FilePresetRepository!

    override func setUpWithError() throws {
        try super.setUpWithError()
        presetsRoot = try makeSubdirectory("Presets")
        repository = FilePresetRepository(scope: .myPresets(rootURL: presetsRoot))
    }

    private func makePreset(
        id: UUID = UUID(),
        name: String = "Golden Hour",
        exposure: Double = 0.5
    ) -> PresetDocument {
        PresetDocument(
            id: id,
            name: name,
            patch: AdjustmentPatch(basic: BasicAdjustmentPatch(exposure: exposure))
        )
    }

    // MARK: - Layout

    func testUsesUUIDBasedFilenames() async throws {
        let preset = makePreset()
        _ = try await repository.save(preset, conflict: .cancel)
        let url = presetsRoot.appendingPathComponent("\(preset.id.uuidString).lhpreset")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Round trip

    func testSaveThenLoadRoundTrips() async throws {
        let preset = makePreset()
        let result = try await repository.save(preset, conflict: .cancel)
        XCTAssertEqual(result, .created)

        let loaded = try await repository.load(id: preset.id)
        XCTAssertEqual(loaded?.id, preset.id)
        XCTAssertEqual(loaded?.name, preset.name)
        XCTAssertEqual(loaded?.patch, preset.patch)
    }

    func testLoadingAMissingPresetReturnsNilNotAnError() async throws {
        let loaded = try await repository.load(id: UUID())
        XCTAssertNil(loaded)
    }

    func testListReturnsEmptyArrayWhenNoPresetsHaveBeenSaved() async throws {
        // The `presets/` subdirectory doesn't exist yet -- absence of data,
        // not an availability failure.
        let empty = try await repository.list()
        XCTAssertEqual(empty, [])
    }

    func testListReturnsEverySavedPreset() async throws {
        let a = makePreset(name: "A")
        let b = makePreset(name: "B")
        _ = try await repository.save(a, conflict: .cancel)
        _ = try await repository.save(b, conflict: .cancel)

        let listed = try await repository.list()
        XCTAssertEqual(Set(listed.map(\.id)), [a.id, b.id])
    }

    // MARK: - Identity: same name, different UUID coexist (spec §8.2)

    func testSameNameDifferentUUIDCoexist() async throws {
        let first = makePreset(name: "Golden Hour")
        let second = makePreset(name: "Golden Hour")
        XCTAssertNotEqual(first.id, second.id)

        let firstResult = try await repository.save(first, conflict: .cancel)
        let secondResult = try await repository.save(second, conflict: .cancel)
        XCTAssertEqual(firstResult, .created)
        XCTAssertEqual(secondResult, .created)

        let listed = try await repository.list()
        XCTAssertEqual(listed.count, 2)
    }

    // MARK: - Conflict resolution (spec §8.2)

    func testSameUUIDAndSameCanonicalContentIsSkipped() async throws {
        let preset = makePreset()
        let first = try await repository.save(preset, conflict: .cancel)
        let second = try await repository.save(preset, conflict: .cancel)
        XCTAssertEqual(first, .created)
        XCTAssertEqual(second, .duplicateSkipped)
    }

    func testDuplicateContentIsSkippedEvenIfTimestampsDiffer() async throws {
        // `createdAt`/`modifiedAt` are metadata about *when*, not part of the
        // preset's observable content -- two saves separated by a fresh
        // `Date()` must still count as the same canonical content.
        let id = UUID()
        let first = PresetDocument(
            id: id, name: "Golden Hour", createdAt: Date(timeIntervalSince1970: 0),
            modifiedAt: Date(timeIntervalSince1970: 0),
            patch: AdjustmentPatch(basic: BasicAdjustmentPatch(exposure: 0.5))
        )
        let second = PresetDocument(
            id: id, name: "Golden Hour", createdAt: Date(),
            modifiedAt: Date(),
            patch: AdjustmentPatch(basic: BasicAdjustmentPatch(exposure: 0.5))
        )
        _ = try await repository.save(first, conflict: .cancel)
        let secondResult = try await repository.save(second, conflict: .cancel)
        XCTAssertEqual(secondResult, .duplicateSkipped)
    }

    func testSameUUIDDifferentContentWithCancelWritesNothing() async throws {
        let id = UUID()
        let original = makePreset(id: id, exposure: 0.5)
        let conflicting = makePreset(id: id, exposure: 1.5)
        _ = try await repository.save(original, conflict: .cancel)

        let result = try await repository.save(conflicting, conflict: .cancel)
        XCTAssertEqual(result, .cancelled)

        let stillOriginal = try await repository.load(id: id)
        XCTAssertEqual(stillOriginal?.patch.basic?.exposure, 0.5)
    }

    func testSameUUIDDifferentContentWithReplaceOverwritesInPlace() async throws {
        let id = UUID()
        let original = makePreset(id: id, exposure: 0.5)
        let replacement = makePreset(id: id, exposure: 1.5)
        _ = try await repository.save(original, conflict: .cancel)

        let result = try await repository.save(replacement, conflict: .replace)
        XCTAssertEqual(result, .replaced)

        let loaded = try await repository.load(id: id)
        XCTAssertEqual(loaded?.patch.basic?.exposure, 1.5)
        let afterReplace = try await repository.list()
        XCTAssertEqual(afterReplace.count, 1, "Replace must not leave a second file behind")
    }

    func testSameUUIDDifferentContentWithKeepBothMintsANewUUID() async throws {
        let id = UUID()
        let original = makePreset(id: id, exposure: 0.5)
        let incoming = makePreset(id: id, exposure: 1.5)
        _ = try await repository.save(original, conflict: .cancel)

        let result = try await repository.save(incoming, conflict: .keepBoth)
        guard case .keptBoth(let newID) = result else {
            return XCTFail("Expected .keptBoth, got \(result)")
        }
        XCTAssertNotEqual(newID, id)

        let originalStillThere = try await repository.load(id: id)
        XCTAssertEqual(originalStillThere?.patch.basic?.exposure, 0.5)
        let keptCopy = try await repository.load(id: newID)
        XCTAssertEqual(keptCopy?.patch.basic?.exposure, 1.5)
        let afterKeepBoth = try await repository.list()
        XCTAssertEqual(afterKeepBoth.count, 2)
    }

    // MARK: - Deletion

    func testDeleteRemovesTheFile() async throws {
        let preset = makePreset()
        _ = try await repository.save(preset, conflict: .cancel)
        try await repository.delete(id: preset.id)
        let loaded = try await repository.load(id: preset.id)
        XCTAssertNil(loaded)
    }

    func testDeletingAMissingPresetIsANoOp() async throws {
        try await repository.delete(id: UUID())
    }

    // MARK: - Offline scope (spec §10)

    func testOfflineScopeThrowsDestinationUnavailableForEveryOperation() async throws {
        let missing = temporaryDirectory.appendingPathComponent("NotMounted", isDirectory: true)
        let offline = FilePresetRepository(scope: .myPresets(rootURL: missing))

        await assertThrowsDestinationUnavailable { _ = try await offline.list() }
        await assertThrowsDestinationUnavailable { _ = try await offline.load(id: UUID()) }
        await assertThrowsDestinationUnavailable { _ = try await offline.save(self.makePreset(), conflict: .cancel) }
        await assertThrowsDestinationUnavailable { try await offline.delete(id: UUID()) }
    }

    private func assertThrowsDestinationUnavailable(
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected .destinationUnavailable", file: file, line: line)
        } catch PresetError.destinationUnavailable {
            // expected
        } catch {
            XCTFail("Expected .destinationUnavailable, got \(error)", file: file, line: line)
        }
    }

    // MARK: - Read-only scope (spec §8.1: "照片庫唯讀時仍可讀取及套用 library preset")

    func testReadOnlyScopeStillAllowsListAndLoad() async throws {
        try XCTSkipUnless(canSimulateReadOnlyDirectory, "Test must not run as root")

        let preset = makePreset()
        _ = try await repository.save(preset, conflict: .cancel)

        try setPosixPermissions(0o555, at: presetsRoot)
        defer { try? setPosixPermissions(0o755, at: presetsRoot) }

        let listed = try await repository.list()
        XCTAssertEqual(listed.map(\.id), [preset.id])
        let loaded = try await repository.load(id: preset.id)
        XCTAssertEqual(loaded?.id, preset.id)
    }

    func testReadOnlyScopeRefusesSave() async throws {
        try XCTSkipUnless(canSimulateReadOnlyDirectory, "Test must not run as root")

        try setPosixPermissions(0o555, at: presetsRoot)
        defer { try? setPosixPermissions(0o755, at: presetsRoot) }

        do {
            _ = try await repository.save(makePreset(), conflict: .cancel)
            XCTFail("Expected .readOnlyDestination")
        } catch PresetError.readOnlyDestination {
            // expected
        }
    }

    func testReadOnlyScopeRefusesDelete() async throws {
        try XCTSkipUnless(canSimulateReadOnlyDirectory, "Test must not run as root")

        let preset = makePreset()
        _ = try await repository.save(preset, conflict: .cancel)

        try setPosixPermissions(0o555, at: presetsRoot)
        defer { try? setPosixPermissions(0o755, at: presetsRoot) }

        do {
            try await repository.delete(id: preset.id)
            XCTFail("Expected .readOnlyDestination")
        } catch PresetError.readOnlyDestination {
            // expected
        }
    }

    // MARK: - Library scope path shape

    func testLibraryScopeIsRootedUnderDotLumaHarborPresets() async throws {
        let libraryRoot = try makeSubdirectory("Library")
        let library = FilePresetRepository(scope: .libraryPresets(libraryRootURL: libraryRoot))
        let preset = makePreset()
        _ = try await library.save(preset, conflict: .cancel)

        let expectedURL = libraryRoot
            .appendingPathComponent(".lumaharbor", isDirectory: true)
            .appendingPathComponent("presets", isDirectory: true)
            .appendingPathComponent("\(preset.id.uuidString).lhpreset")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedURL.path))
    }

    // MARK: - Cross-scope transfer (spec §8.2: copy-then-verify-then-delete)

    func testTransferMovesFromSourceToDestination() async throws {
        let sourceRoot = try makeSubdirectory("Source")
        let destinationRoot = try makeSubdirectory("Destination")
        let source = FilePresetRepository(scope: .myPresets(rootURL: sourceRoot))
        let destination = FilePresetRepository(scope: .myPresets(rootURL: destinationRoot))
        let preset = makePreset()
        _ = try await source.save(preset, conflict: .cancel)

        let result = try await transferPreset(id: preset.id, from: source, to: destination, conflict: .cancel)
        XCTAssertEqual(result, .moved)

        let atDestination = try await destination.load(id: preset.id)
        XCTAssertEqual(atDestination?.patch, preset.patch)
        let atSource = try await source.load(id: preset.id)
        XCTAssertNil(atSource, "The source copy must be gone after a successful move")
    }

    func testTransferOfMissingPresetThrowsSourceNotFound() async throws {
        let sourceRoot = try makeSubdirectory("Source")
        let destinationRoot = try makeSubdirectory("Destination")
        let source = FilePresetRepository(scope: .myPresets(rootURL: sourceRoot))
        let destination = FilePresetRepository(scope: .myPresets(rootURL: destinationRoot))

        do {
            _ = try await transferPreset(id: UUID(), from: source, to: destination, conflict: .cancel)
            XCTFail("Expected .sourceNotFound")
        } catch let error as PresetTransferError {
            guard case .sourceNotFound = error else {
                return XCTFail("Expected .sourceNotFound, got \(error)")
            }
        }
    }

    func testTransferCancelledOnConflictLeavesBothSidesUntouched() async throws {
        let sourceRoot = try makeSubdirectory("Source")
        let destinationRoot = try makeSubdirectory("Destination")
        let source = FilePresetRepository(scope: .myPresets(rootURL: sourceRoot))
        let destination = FilePresetRepository(scope: .myPresets(rootURL: destinationRoot))

        let id = UUID()
        let atSource = makePreset(id: id, exposure: 0.5)
        let conflictingAtDestination = makePreset(id: id, exposure: 9.0)
        _ = try await source.save(atSource, conflict: .cancel)
        _ = try await destination.save(conflictingAtDestination, conflict: .cancel)

        let result = try await transferPreset(id: id, from: source, to: destination, conflict: .cancel)
        XCTAssertEqual(result, .cancelled)

        // Nothing moved: the source copy is untouched and the destination's
        // pre-existing, different document was not overwritten.
        let sourceAfter = try await source.load(id: id)
        let destinationAfter = try await destination.load(id: id)
        XCTAssertEqual(sourceAfter?.patch.basic?.exposure, 0.5)
        XCTAssertEqual(destinationAfter?.patch.basic?.exposure, 9.0)
    }

    func testTransferReportsCopiedSourceRetainedWhenSourceDeleteFails() async throws {
        try XCTSkipUnless(canSimulateReadOnlyDirectory, "Test must not run as root")

        let sourceRoot = try makeSubdirectory("Source")
        let destinationRoot = try makeSubdirectory("Destination")
        let source = FilePresetRepository(scope: .myPresets(rootURL: sourceRoot))
        let destination = FilePresetRepository(scope: .myPresets(rootURL: destinationRoot))
        let preset = makePreset()
        _ = try await source.save(preset, conflict: .cancel)

        try setPosixPermissions(0o555, at: sourceRoot)
        defer { try? setPosixPermissions(0o755, at: sourceRoot) }

        let result = try await transferPreset(id: preset.id, from: source, to: destination, conflict: .cancel)
        guard case .copiedSourceRetained(let reason) = result else {
            return XCTFail("Expected .copiedSourceRetained, got \(result)")
        }
        XCTAssertFalse(reason.isEmpty)

        // The destination has the verified copy, and the source file, unable
        // to be deleted, is still exactly where it was -- never a silent loss.
        let atDestination = try await destination.load(id: preset.id)
        let atSource = try await source.load(id: preset.id)
        XCTAssertEqual(atDestination?.patch, preset.patch)
        XCTAssertEqual(atSource?.patch, preset.patch)
    }
}
