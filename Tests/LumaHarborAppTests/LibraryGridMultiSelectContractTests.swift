import Foundation
import XCTest

/// Same source-parsing approach as `PresetBrowserFoundationContractTests`
/// (see its own header comment) -- this package has no third-party SwiftUI
/// view-inspection dependency. Phase 3 Task 3.3: cmd-clicking a thumbnail
/// must add it to the batch sync target set without opening it, and the
/// grid must show *something* distinguishing a batch-selected cell from
/// both an unselected one and the actively-open one.
final class LibraryGridMultiSelectContractTests: XCTestCase {
    private static let repositoryRootURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // LibraryGridMultiSelectContractTests.swift
            .deletingLastPathComponent() // LumaHarborAppTests
            .deletingLastPathComponent() // Tests
    }()

    private static func loadSource(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRootURL.appendingPathComponent(relativePath, isDirectory: false),
            encoding: .utf8
        )
    }

    func testCommandClickTogglesMultiSelectInsteadOfOpeningThePhoto() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/LibraryGridView.swift")
        XCTAssertTrue(
            source.contains("NSEvent.modifierFlags.contains(.command)"),
            "a Cmd-click must be distinguished from a plain click"
        )
        XCTAssertTrue(source.contains("model.toggleMultiSelect("), "a Cmd-click must add/remove the photo from the batch target set")
    }

    func testGridCellShowsABatchSelectionIndicatorDistinctFromTheOpenPhotoRing() throws {
        let gridSource = try Self.loadSource("Sources/LumaHarborApp/Views/LibraryGridView.swift")
        XCTAssertTrue(
            gridSource.contains("model.selectedPhotoIDs.contains(photo.id)"),
            "the grid must tell each cell whether it's part of the current batch selection"
        )

        let cellSource = try Self.loadSource("Sources/LumaHarborApp/Views/ThumbnailView.swift")
        XCTAssertTrue(cellSource.contains("isBatchSelected"), "the cell must accept a batch-selection flag distinct from isSelected")
    }
}
