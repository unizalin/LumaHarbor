import Foundation
import XCTest
@testable import LumaHarborApp
@testable import PhotoLibraryCore
@testable import RawProcessingCore

/// Phase 3 Task 3.5, end to end through `LibraryViewModel`: a virtual copy
/// must appear grouped right next to its original in `photos` (not just
/// wherever its own capture date/filename would otherwise place it), and
/// `duplicateAsVirtualCopy`/`deleteVirtualCopy` must behave correctly
/// against the real editor/selection state, not just the service layer
/// underneath (already covered by `VirtualCopyServiceTests` in
/// `PhotoLibraryCoreTests`).
@MainActor
final class VirtualCopyLibraryViewModelTests: AppViewModelTestCase {
    /// Baseline case: right after creating a copy, it shares its original's
    /// `relativePath` (and both have no capture date on these fixtures), so
    /// `displayOrder`'s own comparator already ties them together and this
    /// passes even without `orderedForDisplay`'s dedicated grouping code --
    /// it's `testACopyStaysGroupedWithItsOriginalAfterTheOriginalIsRenamed`
    /// below that actually exercises grouping specifically, once that tie
    /// no longer holds. Kept here anyway as the straightforward, common-case
    /// regression check the roadmap's own "variants appear adjacent to
    /// original" bullet asks for.
    func testCreatingAVirtualCopyGroupsItRightAfterItsOriginal() async throws {
        try seedPhotos(["A.ARW", "B.ARW", "C.ARW"])
        let services = try makeServices()
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)
        let model = await makeModel(services: services, libraryID: library.id)
        let photoA = try XCTUnwrap(model.photos.first { $0.relativePath == "A.ARW" })

        await model.duplicateAsVirtualCopy(photoA, named: "Copy of A")

        XCTAssertEqual(model.photos.count, 4)
        let aIndex = try XCTUnwrap(model.photos.firstIndex { $0.id == photoA.id })
        let copy = try XCTUnwrap(model.photos.first { $0.variantOf == photoA.id })
        let copyIndex = try XCTUnwrap(model.photos.firstIndex { $0.id == copy.id })
        XCTAssertEqual(copyIndex, aIndex + 1, "the copy must sit immediately after its original")
        XCTAssertEqual(copy.variantName, "Copy of A")
    }

    func testTwoCopiesOfTheSameOriginalBothGroupNextToItInCreationOrder() async throws {
        try seedPhotos(["A.ARW", "B.ARW", "C.ARW"])
        let services = try makeServices()
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)
        let model = await makeModel(services: services, libraryID: library.id)
        let photoA = try XCTUnwrap(model.photos.first { $0.relativePath == "A.ARW" })

        await model.duplicateAsVirtualCopy(photoA, named: "First")
        await model.duplicateAsVirtualCopy(photoA, named: "Second")

        let aIndex = try XCTUnwrap(model.photos.firstIndex { $0.id == photoA.id })
        XCTAssertEqual(model.photos.count, 5)
        XCTAssertEqual(model.photos[aIndex + 1].variantName, "First")
        XCTAssertEqual(model.photos[aIndex + 2].variantName, "Second")
        // Both copies must still land before B and C, not just before each other.
        let bIndex = try XCTUnwrap(model.photos.firstIndex { $0.relativePath == "B.ARW" && $0.variantOf == nil })
        XCTAssertEqual(bIndex, aIndex + 3)
    }

    /// The real test of `orderedForDisplay`'s own grouping (see its doc
    /// comment): a virtual copy's `relativePath` is frozen at creation time
    /// and never touched by scanning, but the *original* can still be
    /// renamed/moved and relinked to a new path by an ordinary rescan. Once
    /// that happens, the copy's own (stale) path no longer matches the
    /// original's (current) one, so `displayOrder`'s relativePath tie-break
    /// alone would separate them -- proving grouping-by-`variantOf`
    /// actually does something, not just something that happens to already
    /// be true.
    func testACopyStaysGroupedWithItsOriginalAfterTheOriginalIsRenamed() async throws {
        try seedPhotos(["A.ARW", "B.ARW", "C.ARW"])
        let services = try makeServices()
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)
        let model = await makeModel(services: services, libraryID: library.id)
        let photoA = try XCTUnwrap(model.photos.first { $0.relativePath == "A.ARW" })
        await model.duplicateAsVirtualCopy(photoA, named: "Copy of A")
        let copy = try XCTUnwrap(model.photos.first { $0.variantOf == photoA.id })

        // Rename the original's own file on disk, then rescan -- an
        // ordinary "the user renamed a file in Finder" relink. The copy's
        // own row is never touched by this: it keeps recording "A.ARW".
        try FileManager.default.moveItem(
            at: libraryRoot.appendingPathComponent("A.ARW"),
            to: libraryRoot.appendingPathComponent("Z.ARW")
        )
        // Driven through the model itself, not the bare service -- only
        // `model.startScan()` refreshes `model.photos` afterward.
        model.startScan()
        await waitUntilAppCondition("the rescan to finish") {
            await MainActor.run { model.scanProgress?.isFinished == true }
        }

        let renamedOriginal = try XCTUnwrap(model.photos.first { $0.id == photoA.id })
        XCTAssertEqual(renamedOriginal.relativePath, "Z.ARW", "sanity check: the rename actually relinked, not created a new photo")
        let reloadedCopy = try XCTUnwrap(model.photos.first { $0.id == copy.id })
        XCTAssertEqual(reloadedCopy.relativePath, "A.ARW", "sanity check: a virtual copy's own path is frozen, never relinked")

        let originalIndex = try XCTUnwrap(model.photos.firstIndex { $0.id == photoA.id })
        let copyIndex = try XCTUnwrap(model.photos.firstIndex { $0.id == copy.id })
        XCTAssertEqual(copyIndex, originalIndex + 1, "the copy must follow its original to its new position, not stay parked at the original's old path")
    }

    /// `createVirtualCopy(of:)` explicitly allows a copy of a copy (its own
    /// doc comment: "works whether `photo` is itself an original or another
    /// virtual copy") and `LibraryGridView`'s own context menu offers
    /// "Duplicate as Virtual Copy" on every photo unconditionally -- so a
    /// user really can reach this through the app, not just through the
    /// service layer directly. `orderedForDisplay` must still surface that
    /// second-generation copy somewhere in `photos`, not silently drop it.
    func testACopyOfAVirtualCopyStillAppearsInTheGrid() async throws {
        try seedPhotos(["A.ARW"])
        let services = try makeServices()
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)
        let model = await makeModel(services: services, libraryID: library.id)
        let photoA = try XCTUnwrap(model.photos.first { $0.relativePath == "A.ARW" })
        await model.duplicateAsVirtualCopy(photoA, named: "First generation")
        let firstCopy = try XCTUnwrap(model.photos.first { $0.variantOf == photoA.id })

        await model.duplicateAsVirtualCopy(firstCopy, named: "Second generation")

        XCTAssertEqual(model.photos.count, 3, "the original and both generations of copy must all be present")
        let secondCopy = try XCTUnwrap(
            model.photos.first { $0.variantName == "Second generation" },
            "a copy of a copy must not silently vanish from the grid"
        )
        XCTAssertEqual(secondCopy.variantOf, firstCopy.id)
    }

    func testDeletingAVirtualCopyThatIsNotOpenLeavesTheOpenPhotoUntouched() async throws {
        try seedPhotos(["A.ARW", "B.ARW"])
        let services = try makeServices()
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)
        let model = await makeModel(services: services, libraryID: library.id)
        let photoA = try XCTUnwrap(model.photos.first { $0.relativePath == "A.ARW" })
        let photoB = try XCTUnwrap(model.photos.first { $0.relativePath == "B.ARW" })
        await model.duplicateAsVirtualCopy(photoA)
        let copy = try XCTUnwrap(model.photos.first { $0.variantOf == photoA.id })

        model.requestSelectPhoto(photoB.id)
        await waitUntilAppCondition("B to open") {
            await MainActor.run { model.editor.photo?.id == photoB.id }
        }

        await model.deleteVirtualCopy(copy)

        XCTAssertEqual(model.editor.photo?.id, photoB.id, "deleting an unrelated copy must not disturb the currently open photo")
        XCTAssertNil(model.photos.first { $0.id == copy.id })
        XCTAssertEqual(model.photos.count, 2)
    }

    func testDeletingTheCurrentlyOpenVirtualCopyClosesTheEditorAndClearsSelection() async throws {
        try seedPhotos(["A.ARW"])
        let services = try makeServices()
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)
        let model = await makeModel(services: services, libraryID: library.id)
        let photoA = try XCTUnwrap(model.photos.first { $0.relativePath == "A.ARW" })
        await model.duplicateAsVirtualCopy(photoA)
        let copy = try XCTUnwrap(model.photos.first { $0.variantOf == photoA.id })

        model.requestSelectPhoto(copy.id)
        await waitUntilAppCondition("the copy to open") {
            await MainActor.run { model.editor.photo?.id == copy.id }
        }

        await model.deleteVirtualCopy(copy)

        XCTAssertNil(model.editor.photo, "the editor must close once its own open photo has been deleted")
        XCTAssertNil(model.selectedPhotoID)
        XCTAssertNil(model.photos.first { $0.id == copy.id })
    }
}
