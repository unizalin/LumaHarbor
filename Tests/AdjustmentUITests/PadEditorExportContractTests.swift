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

        XCTAssertTrue(source.contains("exportOptions.request("))
        XCTAssertTrue(source.contains("exporter.export(request)"))
        XCTAssertTrue(source.contains("ShareLink"))
        XCTAssertTrue(source.contains("PHPhotoLibrary"))
        XCTAssertTrue(source.contains("creationRequestForAssetFromImage"))
    }

    func testPadRootPassesTheSharedExporterIntoTheEditor() throws {
        let source = try Self.loadSource("PadRootView.swift")

        XCTAssertTrue(
            source.contains("PadEditorView(")
                && source.contains("exporter: services.exporter")
                && source.contains("presetLibrary: services.presetLibrary"),
            "the editor must receive the shared preset library from app services"
        )
    }

    func testPadRootHidesLibraryCommandsAndLargeTitleWhileEditing() throws {
        let source = try Self.loadSource("PadRootView.swift")

        XCTAssertTrue(
            source.contains("if editor.document == nil {"),
            "Open RAW and Settings must only be contributed by the library route"
        )
        XCTAssertTrue(source.contains(".navigationTitle(navigationTitle)"))
        XCTAssertTrue(
            source.contains(".navigationBarTitleDisplayMode(editor.document == nil ? .large : .inline)"),
            "the editor must not keep the library's large navigation-title row"
        )
        XCTAssertTrue(
            source.contains("editor.document?.workingURL.deletingPathExtension().lastPathComponent"),
            "the compact editor title should identify the open photo"
        )
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

    func testEditorWiresCompareModesToCanvasAndToolbar() throws {
        let source = try Self.loadSource("PadEditorView.swift")
        XCTAssertTrue(source.contains("setCompareMode(.single)"))
        XCTAssertTrue(source.contains("setCompareMode(.sideBySide)"))
        XCTAssertTrue(source.contains("setCompareMode(.verticalWipe)"))
        XCTAssertTrue(source.contains("comparisonCanvas"))
        XCTAssertTrue(source.contains("setWipePosition"))
    }

    func testEditorWiresLibraryFilmstripWithoutDuplicatingPhotoData() throws {
        let source = try Self.loadSource("PadEditorView.swift")
        XCTAssertTrue(source.contains("PadEditorFilmstrip"))
        XCTAssertTrue(source.contains("library.photos"))
        XCTAssertTrue(source.contains("library.openAsset(for: photo)"))
        XCTAssertTrue(source.contains("model.openLibraryAsset(asset)"))
    }
}
