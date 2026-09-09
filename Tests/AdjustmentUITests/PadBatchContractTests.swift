import Foundation
import XCTest

/// Source contract for the first touch-first batch action. The actual
/// transaction is owned by PhotoLibraryCore; this test guards that the iPad
/// surface calls it through the shared service and refreshes the same query.
final class PadBatchContractTests: XCTestCase {
    private static let repositoryRootURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }()

    private static func loadSource(_ path: String) throws -> String {
        try String(
            contentsOf: repositoryRootURL.appendingPathComponent(path),
            encoding: .utf8
        )
    }

    func testSelectionBarExposesVirtualCopyAction() throws {
        let source = try Self.loadSource("Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadLibraryGrid.swift")
        XCTAssertTrue(source.contains("Create virtual copies"))
        XCTAssertTrue(source.contains("createVirtualCopy(of: photo)"))
        XCTAssertTrue(source.contains("library.refresh()"))
    }

    func testLibrarySessionRefreshClearsPresentationSelection() throws {
        let source = try Self.loadSource("Sources/EditorCore/LibraryBrowserSession.swift")
        XCTAssertTrue(source.contains("public func refresh()"))
        XCTAssertTrue(source.contains("selectedPhotoIDs.removeAll()"))
        XCTAssertTrue(source.contains("beginNewQuery()"))
    }

    func testEditorAndServicesExposeBatchSyncHooks() throws {
        let dependencies = try Self.loadSource("Sources/EditorCore/PhotoDocumentEditor.swift")
        XCTAssertTrue(dependencies.contains("onBeginAdjustmentGesture"))
        XCTAssertTrue(dependencies.contains("onEndAdjustmentGesture"))

        let services = try Self.loadSource("Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadAppServices.swift")
        XCTAssertTrue(services.contains("batchCoordinator"))

        let coordinator = try Self.loadSource("Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadBatchAdjustmentCoordinator.swift")
        XCTAssertTrue(coordinator.contains("beginGesture"))
        XCTAssertTrue(coordinator.contains("undoLastTransaction"))
    }

    func testEditorFileExporterUsesSelectedExportFormat() throws {
        let source = try Self.loadSource("Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorView.swift")
        XCTAssertTrue(source.contains("UTType(exportOptions.format.utTypeIdentifier)"))
        XCTAssertFalse(source.contains("contentType: .jpeg"))
    }

    func testInfoDomainExposesDurableCurationControls() throws {
        let source = try Self.loadSource("Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorView.swift")
        XCTAssertTrue(source.contains("setRating"))
        XCTAssertTrue(source.contains("setFlag"))
        XCTAssertTrue(source.contains("setKeywords"))
        XCTAssertTrue(source.contains("Keywords"))
        let coordinator = try Self.loadSource("Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadBatchAdjustmentCoordinator.swift")
        XCTAssertTrue(coordinator.contains("updatePhotoCuration"))
    }

    func testLibrarySelectionBarExposesBatchCurationActions() throws {
        let source = try Self.loadSource("Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadLibraryGrid.swift")
        XCTAssertTrue(source.contains("applyRatingToSelected"))
        XCTAssertTrue(source.contains("applyFlagToSelected"))
        XCTAssertTrue(source.contains("applyKeywordsToSelected"))
        XCTAssertTrue(source.contains("Updated %d photos."))
        XCTAssertTrue(source.contains("Updated %d of %d photos."))
    }
}
