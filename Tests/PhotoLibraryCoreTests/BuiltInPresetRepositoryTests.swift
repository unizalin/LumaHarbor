import XCTest
@testable import PhotoLibraryCore
@testable import PresetCore

/// Phase 3 Task 3.1: a third, read-only `PresetRepository` scope, proving
/// the built-in-vs-user precedence mechanism -- coexistence via a distinct
/// scope, never a forced identity/name conflict with anything in "My
/// Presets" or "This Library" -- without shipping a curated creative preset
/// library (a product/content decision, deliberately out of scope for this
/// foundation round; see `BuiltInPresetRepository.defaultPresets`'s own doc
/// comment).
final class BuiltInPresetRepositoryTests: XCTestCase {
    private let repository = BuiltInPresetRepository()

    func testListReturnsTheDefaultBuiltInPresets() async throws {
        let listed = try await repository.list()
        XCTAssertFalse(listed.isEmpty, "the mechanism needs at least one preset to actually prove itself")
        XCTAssertEqual(listed.map(\.id).count, Set(listed.map(\.id)).count, "every built-in preset must have a distinct, stable identity")
    }

    func testEveryBuiltInPresetIsNativeSourcedAndHasAtLeastOneField() async throws {
        let listed = try await repository.list()
        for preset in listed {
            XCTAssertEqual(preset.source, .native, "\(preset.name) should not claim to be an imported XMP preset")
            XCTAssertFalse(preset.patch.isEmpty, "\(preset.name) must actually do something, or it isn't proving anything")
        }
    }

    func testLoadFindsAPresetByID() async throws {
        let listed = try await repository.list()
        let first = try XCTUnwrap(listed.first)
        let loaded = try await repository.load(id: first.id)
        XCTAssertEqual(loaded, first)
    }

    func testLoadReturnsNilForAnUnknownID() async throws {
        let loaded = try await repository.load(id: UUID())
        XCTAssertNil(loaded)
    }

    func testBuiltInPresetIdentityIsStableAcrossInstances() async throws {
        let a = try await BuiltInPresetRepository().list()
        let b = try await BuiltInPresetRepository().list()
        XCTAssertEqual(Set(a.map(\.id)), Set(b.map(\.id)), "a fresh instance must expose the exact same identities, not regenerate random UUIDs")
    }

    func testSaveIsRejectedAsReadOnly() async throws {
        let listed = try await repository.list()
        let existing = try XCTUnwrap(listed.first)
        do {
            _ = try await repository.save(existing, conflict: .replace)
            XCTFail("saving to the built-in scope must never succeed")
        } catch PresetError.builtInPresetIsReadOnly {
            // expected
        }
    }

    func testDeleteIsRejectedAsReadOnly() async throws {
        let listed = try await repository.list()
        let existing = try XCTUnwrap(listed.first)
        do {
            try await repository.delete(id: existing.id)
            XCTFail("deleting from the built-in scope must never succeed")
        } catch PresetError.builtInPresetIsReadOnly {
            // expected
        }
    }
}
