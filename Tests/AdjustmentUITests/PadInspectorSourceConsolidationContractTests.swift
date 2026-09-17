import Foundation
import XCTest

/// Phase 0 source-ownership contracts. The iPad SwiftPM and Xcode targets
/// must compile the same Inspector host and tool rail, with no file-local copy
/// left in PadEditorView.swift.
final class PadInspectorSourceConsolidationContractTests: XCTestCase {
    private static let repositoryRootURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AdjustmentUITests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository root
    }()

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: Self.repositoryRootURL.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    func testPadEditorViewDoesNotContainInlineInspectorTypes() throws {
        let source = try source("Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorView.swift")

        XCTAssertFalse(source.contains("// MARK: - PadToolRail (inlined"))
        XCTAssertFalse(source.contains("// MARK: - PadInspectorHost (inlined"))
        XCTAssertFalse(source.contains("private struct PadToolRail"))
        XCTAssertFalse(source.contains("private struct PadInspectorHost"))
    }

    func testCanonicalInspectorFilesEachDeclareExactlyOneMatchingType() throws {
        let rail = try source("Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadToolRail.swift")
        let host = try source("Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadInspectorHost.swift")

        XCTAssertEqual(
            rail.components(separatedBy: "struct PadToolRail:").count - 1,
            1,
            "PadToolRail must have exactly one canonical declaration"
        )
        XCTAssertEqual(
            host.components(separatedBy: "struct PadInspectorHost:").count - 1,
            1,
            "PadInspectorHost must have exactly one canonical declaration"
        )
    }

    func testXcodeProjectListsCanonicalInspectorSources() throws {
        let project = try source("Apps/LumaHarborPad.xcodeproj/project.pbxproj")

        for fileName in ["PadToolRail.swift", "PadInspectorHost.swift"] {
            XCTAssertTrue(project.contains("path = \(fileName);"), "missing PBXFileReference for \(fileName)")
            XCTAssertTrue(project.contains("\(fileName) in Sources"), "missing PBXSourcesBuildPhase entry for \(fileName)")
        }
    }
}
