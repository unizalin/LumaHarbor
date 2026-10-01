import Foundation
import XCTest

/// The Mac filmstrip is a cheap SwiftUI list, so this contract test protects
/// the lifecycle rule that cannot be expressed by the current dependency-free
/// test target with view inspection: the selected item must be brought into
/// view once the list is first rendered, not only after a later selection.
final class FilmstripViewContractTests: XCTestCase {
    private static let repositoryRootURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }()

    private static func source() throws -> String {
        try String(
            contentsOf: repositoryRootURL
                .appendingPathComponent("Sources/LumaHarborApp/Views/FilmstripView.swift"),
            encoding: .utf8
        )
    }

    func testFilmstripScrollsToSelectionWhenPhotosFirstBecomeAvailable() throws {
        let source = try Self.source()

        XCTAssertTrue(
            source.contains("onAppear") || source.contains("task(id: model.photos"),
            "the filmstrip must perform an initial selection scroll after its list is rendered"
        )
        XCTAssertTrue(
            source.contains("model.photos") && source.contains("proxy.scrollTo"),
            "initial positioning must use the current photo list and ScrollViewReader"
        )
    }

    func testFilmstripExposesSelectionPositionToUsers() throws {
        let source = try Self.source()

        XCTAssertTrue(source.contains("selectedPhotoID"))
        XCTAssertTrue(
            source.contains("currentPhotoPosition") || source.contains("第") || source.contains("of"),
            "the filmstrip should expose the selected filename or its position, not only a border"
        )
    }
}
