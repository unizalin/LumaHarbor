import Foundation
import XCTest

final class ReleaseVersionContractTests: XCTestCase {
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private struct BundleMetadata {
        let version: String
        let build: String
    }

    private enum ContractError: Error {
        case missingMetadataKey(String)
        case invalidMetadataValue(String)
    }

    private func url(_ path: String) -> URL {
        Self.repositoryRoot.appendingPathComponent(path)
    }

    private func text(_ path: String) throws -> String {
        try String(contentsOf: url(path), encoding: .utf8)
    }

    func testMacAndIPadUseTheSameSemanticVersion() throws {
        let mac = try macBundleMetadata()
        let project = try text("Apps/LumaHarborPad.xcodeproj/project.pbxproj")
        let ipadVersions = values(for: "MARKETING_VERSION", in: project)

        XCTAssertTrue(
            mac.version.range(
                of: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"#,
                options: .regularExpression
            ) != nil
        )
        XCTAssertEqual(Set(ipadVersions), Set([mac.version]))
        XCTAssertEqual(ipadVersions.count, 2)
    }

    func testMacAndIPadUseTheSamePositiveInternalBuild() throws {
        let mac = try macBundleMetadata()
        let project = try text("Apps/LumaHarborPad.xcodeproj/project.pbxproj")
        let ipadBuilds = values(for: "CURRENT_PROJECT_VERSION", in: project)

        XCTAssertGreaterThan(Int(mac.build) ?? 0, 0)
        XCTAssertEqual(Set(ipadBuilds), Set([mac.build]))
        XCTAssertEqual(ipadBuilds.count, 2)
    }

    func testPublicDocumentationUsesVersionOnlyArtifactNames() throws {
        let readme = try text("README.md")
        let legacyArchiveName = "LumaHarbor-<version>" + "-<build>.zip"
        let legacyProductName = "0.1.0 " + "(3)"

        XCTAssertTrue(readme.contains("LumaHarbor-<version>.zip"))
        XCTAssertFalse(readme.contains(legacyArchiveName))
        XCTAssertFalse(readme.contains(legacyProductName))
    }

    func testAgentAndWorkflowDocsSeparateProductVersionFromInternalBuild() throws {
        let agents = try text("AGENTS.md")
        let workflow = try text("docs/coordination/SHARED_GIT_WORKFLOW.md")
        let decisions = try text("docs/coordination/DECISIONS.md")

        XCTAssertTrue(agents.contains("MAJOR.MINOR.PATCH"))
        XCTAssertTrue(agents.contains("internal build"))
        XCTAssertTrue(workflow.contains("產品版本"))
        XCTAssertTrue(workflow.contains("內部 build"))
        XCTAssertTrue(decisions.contains("D-011 — Public releases use semantic versions"))
    }

    private func macBundleMetadata() throws -> BundleMetadata {
        let plistURL = url("Resources/Info.plist")
        let plistData = try Data(contentsOf: plistURL)
        let propertyList = try PropertyListSerialization.propertyList(
            from: plistData,
            options: [],
            format: nil
        )
        guard let dictionary = propertyList as? [String: Any] else {
            throw ContractError.invalidMetadataValue("Info.plist root")
        }
        guard let version = dictionary["CFBundleShortVersionString"] as? String else {
            throw ContractError.missingMetadataKey("CFBundleShortVersionString")
        }
        guard let build = dictionary["CFBundleVersion"] as? String else {
            throw ContractError.missingMetadataKey("CFBundleVersion")
        }
        return BundleMetadata(version: version, build: build)
    }

    private func values(for key: String, in text: String) -> [String] {
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        let pattern = "(?m)^\\s*" + escapedKey + "\\s*=\\s*([^;]+);"
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard let valueRange = Range(match.range(at: 1), in: text) else {
                return nil
            }
            return String(text[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
