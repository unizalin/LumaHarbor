import Foundation
import XCTest

final class PadEditorExportContractTests: XCTestCase {
    private static let repositoryRootURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }()

    private static func loadSource(_ filename: String) throws -> String {
        let url = repositoryRootURL
            .appendingPathComponent("Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp", isDirectory: true)
            .appendingPathComponent(filename)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testPadServicesOwnsTheFullResolutionExporter() throws {
        let source = try Self.loadSource("PadAppServices.swift")

        XCTAssertTrue(source.contains("let exporter: PhotoExporter"))
        XCTAssertTrue(source.contains("PhotoExporter(decoder:"))
    }

    func testPadEditorOffersFullResolutionExportPhotosAndShareActions() throws {
        let source = try Self.loadSource("PadEditorView.swift")

        XCTAssertTrue(source.contains("ExportRequest("))
        XCTAssertTrue(source.contains("quality: 1"))
        XCTAssertTrue(source.contains("ShareLink"))
        XCTAssertTrue(source.contains("PHPhotoLibrary"))
        XCTAssertTrue(source.contains("creationRequestForAssetFromImage"))
    }

    func testPadRootPassesTheSharedExporterIntoTheEditor() throws {
        let source = try Self.loadSource("PadRootView.swift")

        XCTAssertTrue(source.contains("PadEditorView(model: editor, exporter: services.exporter)"))
    }

    // MARK: - Explicit "Save to Files" (spec §5.5.1/§5.5.2)

    func testPadEditorOffersAnExplicitSaveToFilesFileExporterOverTheSameExportedFile() throws {
        let source = try Self.loadSource("PadEditorView.swift")

        XCTAssertTrue(source.contains("isPresentingFileExporter"))
        XCTAssertTrue(source.contains(".fileExporter("))
        XCTAssertTrue(source.contains("ExportedPhotoFileDocument(fileURL: $0)"))
        XCTAssertTrue(
            source.contains("document: exportedURL.map"),
            "Save to Files must reuse exportFullResolution()'s own exportedURL, not run a second export"
        )
    }

    func testFileExporterCancellationIsNeverShownAsAFailureAlert() throws {
        let source = try Self.loadSource("PadEditorView.swift")

        XCTAssertTrue(source.contains(".userCancelled"))
        XCTAssertTrue(source.contains("Couldn't save to Files"))
    }
}
