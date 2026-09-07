import CoreGraphics
import Foundation
import ImageIO
import XCTest

final class AppIconAssetContractTests: XCTestCase {
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func url(_ path: String) -> URL {
        Self.repositoryRoot.appendingPathComponent(path)
    }

    private func text(_ path: String) throws -> String {
        try String(contentsOf: url(path), encoding: .utf8)
    }

    func testMasterIconIsOpaque1024SquarePNG() throws {
        let source = try XCTUnwrap(
            CGImageSourceCreateWithURL(url("Resources/AppIcon-1024.png") as CFURL, nil)
        )
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))

        XCTAssertEqual(image.width, 1024)
        XCTAssertEqual(image.height, 1024)

        let alphaBearingModes: [CGImageAlphaInfo] = [
            .premultipliedFirst,
            .premultipliedLast,
            .first,
            .last,
        ]
        XCTAssertFalse(alphaBearingModes.contains(image.alphaInfo))
    }

    func testMacBundleDeclaresAndCopiesICNS() throws {
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url("Resources/LumaHarbor.icns").path)
        )

        let infoPlist = try text("Resources/Info.plist")
        XCTAssertTrue(infoPlist.contains("CFBundleIconFile"))
        XCTAssertTrue(infoPlist.contains("LumaHarbor.icns"))

        let buildScript = try text("Scripts/build-app-bundle.sh")
        XCTAssertTrue(buildScript.contains("Resources/LumaHarbor.icns"))
    }

    func testIPadAssetCatalogAndProjectAreWired() throws {
        let catalog = try text(
            "Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/Assets.xcassets/" +
                "AppIcon.appiconset/Contents.json"
        )
        XCTAssertTrue(catalog.contains("AppIcon-1024.png"))
        XCTAssertTrue(catalog.contains("1024x1024"))

        let project = try text("Apps/LumaHarborPad.xcodeproj/project.pbxproj")
        XCTAssertTrue(project.contains("Assets.xcassets in Resources"))
        XCTAssertTrue(project.contains("ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;"))
    }

    func testIPadProjectDoesNotContainPersonalBundleIdentifier() throws {
        let project = try text("Apps/LumaHarborPad.xcodeproj/project.pbxproj")
        XCTAssertFalse(project.lowercased().contains("unizalin"))
        XCTAssertTrue(project.contains("PRODUCT_BUNDLE_IDENTIFIER = org.lumaharbor.LumaHarborPad;"))
    }
}
