import Foundation
import XCTest
@testable import PhotoLibraryCore
@testable import RawProcessingCore

final class PhotoDocumentStoreTests: XCTestCase {
    func testOpenInPlaceDoesNotWriteTheSource() async throws {
        let fixture = try TemporaryPhotoDocumentFixture()
        let before = try Data(contentsOf: fixture.sourceURL)
        let document = try await fixture.store.openInPlace(fixture.sourceURL, bookmarkData: nil)
        try await fixture.store.saveAdjustments(.neutral.setting(.exposure, to: 1), documentID: document.id)
        XCTAssertEqual(try Data(contentsOf: fixture.sourceURL), before)
        XCTAssertEqual(document.storageMode, .inPlace)
    }

    func testImportCopyVerifiesBytesAndKeepsSourceLink() async throws {
        let fixture = try TemporaryPhotoDocumentFixture()
        let document = try await fixture.store.importCopy(of: fixture.sourceURL, bookmarkData: nil)
        XCTAssertEqual(document.storageMode, .appCopy)
        XCTAssertEqual(document.sourceFingerprint, document.workingFingerprint)
        XCTAssertNotEqual(document.workingURL, fixture.sourceURL)
        XCTAssertEqual(try Data(contentsOf: document.workingURL), try Data(contentsOf: fixture.sourceURL))
    }

    func testReopeningLoadsTheSavedAdjustments() async throws {
        let fixture = try TemporaryPhotoDocumentFixture()
        let document = try await fixture.store.openInPlace(fixture.sourceURL, bookmarkData: nil)
        let edited = PhotoAdjustments.neutral.setting(.contrast, to: 25)
        try await fixture.store.saveAdjustments(edited, documentID: document.id)
        let reloaded = try await fixture.store.loadAdjustments(documentID: document.id)
        XCTAssertEqual(reloaded, edited)
    }

    func testCopyVerificationFailureLeavesNoDocumentOrRecord() async throws {
        let fixture = try TemporaryPhotoDocumentFixture()
        let failingStoreRoot = fixture.rootURL.appendingPathComponent("FailingStore")
        let store = PhotoDocumentStore(rootURL: failingStoreRoot) { source, destination in
            var bytes = try Data(contentsOf: source)
            bytes[0] ^= 0xff
            try bytes.write(to: destination)
        }

        do {
            _ = try await store.importCopy(of: fixture.sourceURL, bookmarkData: nil)
            XCTFail("Expected copy verification to fail")
        } catch {
            XCTAssertEqual(error as? PhotoDocumentError, .copyVerificationFailed)
        }

        let documents = failingStoreRoot.appendingPathComponent("Documents")
        let records = failingStoreRoot.appendingPathComponent("Records")
        XCTAssertTrue((try? FileManager.default.contentsOfDirectory(atPath: documents.path).isEmpty) ?? true)
        XCTAssertTrue((try? FileManager.default.contentsOfDirectory(atPath: records.path).isEmpty) ?? true)
    }
}

private struct TemporaryPhotoDocumentFixture {
    let rootURL: URL
    let sourceURL: URL
    let store: PhotoDocumentStore

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoDocumentStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        sourceURL = rootURL.appendingPathComponent("fixture.ARW")
        try Data(repeating: 0x5a, count: 4096).write(to: sourceURL)
        store = PhotoDocumentStore(rootURL: rootURL.appendingPathComponent("Store", isDirectory: true))
    }
}
