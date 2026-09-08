import Foundation
import XCTest
@testable import LumaHarborApp
@testable import PhotoLibraryCore
@testable import RawProcessingCore

/// Phase 5 Task 5.2: naming template, collision policy, and watermark
/// options actually reaching `LibraryViewModel`'s single- and batch-export
/// requests, not just existing as unused fields on `MacExportOptions`.
@MainActor
final class ExportOptionsWiringTests: AppViewModelTestCase {
    private func destinationDirectory() throws -> URL {
        let url = temporaryDirectory.appendingPathComponent("ExportOptionsWiringTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Naming template

    func testSingleExportRendersTheSelectedNamingTemplate() async throws {
        try seedPhotos(["A.ARW"])
        let services = try makeServices(decoder: SucceedingRawDecoder())
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)
        let model = await makeModel(services: services, libraryID: library.id)
        let photo = try XCTUnwrap(model.photos.first)
        model.requestSelectPhoto(photo.id)
        await waitUntilAppCondition("the photo to open") { await model.selectedPhotoID == photo.id }

        var options = MacExportOptions.default
        options.namingTemplate = .originalFilenameWithSequence
        options.format = .png
        model.export(photo: photo, to: try destinationDirectory(), options: options)

        await waitUntilAppCondition("the export to finish") { await model.exportState?.isFinished == true }

        XCTAssertEqual(model.exportState?.filename, "A_001.png")
    }

    func testBatchExportNumbersEachFileBySequentialPositionInTheBatch() async throws {
        try seedPhotos(["A.ARW", "B.ARW", "C.ARW"])
        let services = try makeServices(decoder: SucceedingRawDecoder())
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)
        let model = await makeModel(services: services, libraryID: library.id)
        for photo in model.photos {
            model.toggleMultiSelect(photo.id)
        }

        var options = MacExportOptions.default
        options.namingTemplate = .originalFilenameWithSequence
        model.startBatchExport(to: try destinationDirectory(), options: options)

        await waitUntilAppCondition("the batch export to finish") { await !model.isBatchExporting }

        let filenames = model.batchExportItems
            .sorted { $0.request.baseFilename < $1.request.baseFilename }
            .map(\.request.baseFilename)
        XCTAssertEqual(filenames, ["A_001", "B_002", "C_003"])
    }

    func testBatchExportExcludesRejectedPhotosUnlessExplicitlyIncluded() async throws {
        try seedPhotos(["A.ARW", "B.ARW"])
        let services = try makeServices(decoder: SucceedingRawDecoder())
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)
        let index = await services.libraryService.indexStore
        let rejected = try XCTUnwrap(
            try index.photos(inLibrary: library.id).first { $0.relativePath == "B.ARW" }
        )
        try index.setFlag(.reject, for: rejected.id)

        let model = await makeModel(services: services, libraryID: library.id)
        for photo in model.photos { model.toggleMultiSelect(photo.id) }
        model.startBatchExport(to: try destinationDirectory(), options: .default)
        await waitUntilAppCondition("the default batch export to finish") { await !model.isBatchExporting }
        XCTAssertEqual(model.batchExportItems.map(\.request.baseFilename), ["A"])

        model.includeRejectedInBatchExport = true
        model.startBatchExport(to: try destinationDirectory(), options: .default)
        await waitUntilAppCondition("the reject-inclusive batch export to finish") { await !model.isBatchExporting }
        XCTAssertEqual(Set(model.batchExportItems.map(\.request.baseFilename)), ["A", "B"])
    }

    func testNamingTemplateUsesTheVirtualCopysNameWhenExportingACopy() async throws {
        try seedPhotos(["A.ARW"])
        let services = try makeServices(decoder: SucceedingRawDecoder())
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)
        let model = await makeModel(services: services, libraryID: library.id)
        let original = try XCTUnwrap(model.photos.first)
        await model.duplicateAsVirtualCopy(original, named: "B&W")
        let copy = try XCTUnwrap(model.photos.first { $0.variantOf == original.id })
        model.toggleMultiSelect(copy.id)

        var options = MacExportOptions.default
        options.namingTemplate = .originalFilenameWithVirtualCopyName
        model.startBatchExport(to: try destinationDirectory(), options: options)

        await waitUntilAppCondition("the batch export to finish") { await !model.isBatchExporting }

        XCTAssertEqual(model.batchExportItems.first?.request.baseFilename, "A_B&W")
    }

    // MARK: - Collision policy

    func testSingleExportSkipPolicyMarksTheExportStateSkippedRatherThanOverwriting() async throws {
        try seedPhotos(["A.ARW"])
        let services = try makeServices(decoder: SucceedingRawDecoder())
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)
        let model = await makeModel(services: services, libraryID: library.id)
        let photo = try XCTUnwrap(model.photos.first)
        let destination = try destinationDirectory()

        model.export(photo: photo, to: destination, options: .default)
        await waitUntilAppCondition("the first export to finish") { await model.exportState?.isFinished == true }
        let firstPath = try XCTUnwrap(model.exportState?.resultPath)
        let firstBytes = try Data(contentsOf: URL(fileURLWithPath: firstPath))

        var skipOptions = MacExportOptions.default
        skipOptions.collisionPolicy = .skip
        model.export(photo: photo, to: destination, options: skipOptions)
        await waitUntilAppCondition("the second export to finish") { await model.exportState?.isFinished == true }

        XCTAssertEqual(model.exportState?.wasSkipped, true)
        XCTAssertNil(model.exportState?.resultPath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: firstPath)), firstBytes, "skip must never overwrite the existing file")
    }

    func testBatchExportSkipPolicyMarksTheCollidingItemSkippedWithoutStoppingTheRest() async throws {
        try seedPhotos(["A.ARW", "B.ARW"])
        let services = try makeServices(decoder: SucceedingRawDecoder())
        let library = try await addLibrary(services)
        await runScan(services, libraryID: library.id)
        let model = await makeModel(services: services, libraryID: library.id)
        let photoA = try XCTUnwrap(model.photos.first { $0.relativePath == "A.ARW" })
        let photoB = try XCTUnwrap(model.photos.first { $0.relativePath == "B.ARW" })
        let destination = try destinationDirectory()

        // Pre-create "A"'s destination file via a first, ordinary export.
        model.export(photo: photoA, to: destination, options: .default)
        await waitUntilAppCondition("the pre-export to finish") { await model.exportState?.isFinished == true }

        model.toggleMultiSelect(photoA.id)
        model.toggleMultiSelect(photoB.id)
        var options = MacExportOptions.default
        options.collisionPolicy = .skip
        model.startBatchExport(to: destination, options: options)

        await waitUntilAppCondition("the batch export to finish") { await !model.isBatchExporting }

        let itemA = try XCTUnwrap(model.batchExportItems.first { $0.request.baseFilename == "A" })
        let itemB = try XCTUnwrap(model.batchExportItems.first { $0.request.baseFilename == "B" })
        XCTAssertEqual(itemA.status, .skipped)
        guard case .succeeded = itemB.status else {
            return XCTFail("expected B to still export despite A being skipped, got \(itemB.status)")
        }
    }
}
