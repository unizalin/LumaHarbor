import Foundation
import XCTest

/// The editor root composes the universal workspace; feature-heavy view
/// implementations live in focused files so iPad and future iPhone shells
/// can share the same Inspector and canvas owners.
final class PadEditorCompositionContractTests: XCTestCase {
    private static let repositoryRootURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }()

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: Self.repositoryRootURL.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    func testRootComposesFocusedEditorOwners() throws {
        let root = try source("Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorView.swift")

        XCTAssertTrue(root.contains("PadEditorToolbar("))
        XCTAssertTrue(root.contains("PadEditorCanvasView("))
        XCTAssertTrue(root.contains("PadEditorInspectorContainer("))
        XCTAssertGreaterThanOrEqual(
            root.components(separatedBy: "editor: editor").count - 1,
            2,
            "the canvas and Inspector must receive the same EditorSession"
        )
    }

    func testRootDoesNotDeclareExtractedFeatureViews() throws {
        let root = try source("Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorView.swift")

        for declaration in [
            "struct PadPresetPanel:",
            "struct PadExportOptionsSheet:",
            "struct PadCropOverlayView:",
            "struct PadEditorFilmstrip:",
            "struct PadHistogramBlock:",
            "struct PadMetadataBlock:",
            "struct PadSaveStateBlock:"
        ] {
            XCTAssertFalse(root.contains(declaration), "root still owns extracted declaration: \(declaration)")
        }
    }

    func testFocusedEditorSourcesArePresentAndInTheXcodeTarget() throws {
        let project = try source("Apps/LumaHarborPad.xcodeproj/project.pbxproj")
        let fileNames = [
            "PadEditorToolbar.swift",
            "PadEditorCanvasView.swift",
            "PadEditorFilmstrip.swift",
            "PadEditorInspectorContainer.swift",
            "PadEditorExportViews.swift",
            "PadEditorPresetViews.swift",
            "PadEditorInfoViews.swift",
            "PadCropOverlayView.swift"
        ]

        for fileName in fileNames {
            let path = Self.repositoryRootURL
                .appendingPathComponent("Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp")
                .appendingPathComponent(fileName)
            XCTAssertTrue(FileManager.default.fileExists(atPath: path.path), "missing focused source: \(fileName)")
            XCTAssertTrue(project.contains("path = \(fileName);"), "missing PBXFileReference for \(fileName)")
            XCTAssertTrue(project.contains("\(fileName) in Sources"), "missing PBXSourcesBuildPhase entry for \(fileName)")
        }
    }
}
