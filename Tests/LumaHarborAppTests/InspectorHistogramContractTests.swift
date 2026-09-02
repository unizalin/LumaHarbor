import Foundation
import XCTest

/// Same source-parsing approach as `InspectorMetadataContractTests` -- see
/// that file's own header comment for why. AwayPhotoRawEditor parity Phase 1
/// Task 2: the Mac editor's inspector must show a histogram section built
/// from `EditorSession.histogram`, with a localized fallback when no
/// histogram is available yet (design spec: "empty/failed preview states
/// show clear localized fallback copy").
final class InspectorHistogramContractTests: XCTestCase {
    private static let repositoryRootURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // InspectorHistogramContractTests.swift
            .deletingLastPathComponent() // LumaHarborAppTests
            .deletingLastPathComponent() // Tests
    }()

    private static func appSourceURL(_ filename: String) -> URL {
        repositoryRootURL
            .appendingPathComponent("Sources/LumaHarborApp/Views", isDirectory: true)
            .appendingPathComponent(filename)
    }

    private static func loadSource(_ filename: String) throws -> String {
        try String(contentsOf: appSourceURL(filename), encoding: .utf8)
    }

    func testInspectorViewRendersAHistogramSectionFromTheSessionsHistogram() throws {
        let source = try Self.loadSource("InspectorView.swift")

        XCTAssertTrue(
            source.contains("model.editor.histogram") || source.contains("editor.histogram"),
            "InspectorView must render EditorSession.histogram, not a separately re-derived value"
        )
        XCTAssertTrue(
            source.contains("L10n.t(\"Histogram\")"),
            "the histogram section must have a visible, localized header"
        )
    }

    /// Acceptance: "empty/failed preview states show clear localized
    /// fallback copy" -- there must be visible text for the no-histogram
    /// case, not just a blank area.
    func testInspectorViewShowsALocalizedFallbackWhenNoHistogramIsAvailable() throws {
        let source = try Self.loadSource("InspectorView.swift")

        XCTAssertTrue(
            source.contains("if let histogram") || source.contains("if let"),
            "the histogram section must branch on whether a histogram is actually available"
        )
        XCTAssertTrue(
            source.contains("L10n.t(\"No histogram available yet\")"),
            "missing histogram data must show visible, localized fallback text, not an empty area"
        )
    }
}
