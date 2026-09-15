import Foundation
import XCTest

final class MacReleasePackagingContractTests: XCTestCase {
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

    func testBundleBuilderCopiesEveryRequiredSwiftPMResourceBundle() throws {
        let script = try text("Scripts/build-app-bundle.sh")

        XCTAssertTrue(script.contains("LumaHarbor_Localization.bundle"))
        XCTAssertTrue(script.contains("LumaHarbor_RawProcessingCore.bundle"))
        XCTAssertTrue(
            script.contains("cp -R \"${source_bundle}\" \"${APP_DIR}/Contents/Resources/\"")
        )
    }

    func testAppBundleBuildUsesStandardResourceLocationAndCustomLookup() throws {
        let buildScript = try text("Scripts/build-app-bundle.sh")
        let localization = try text("Sources/Localization/L10n.swift")
        let adjustmentPipeline = try text("Sources/RawProcessingCore/Pipeline/AdjustmentPipeline.swift")

        XCTAssertTrue(buildScript.contains("-DLUMAHARBOR_APP_BUNDLE"))
        for source in [localization, adjustmentPipeline] {
            XCTAssertTrue(source.contains("#if LUMAHARBOR_APP_BUNDLE"))
            XCTAssertTrue(source.contains("Bundle.main.resourceURL"))
        }
    }

    func testReleaseBinaryIsStrippedBeforeCodeSigning() throws {
        let script = try text("Scripts/build-app-bundle.sh")
        let stripRange = try XCTUnwrap(script.range(of: "strip -S"))
        let signingRange = try XCTUnwrap(script.range(of: "codesign --force"))

        XCTAssertLessThan(stripRange.lowerBound, signingRange.lowerBound)
    }

    func testMetalCompilerDoesNotEmbedPrivateSourcePaths() throws {
        let plugin = try text("Plugins/CompileMetalKernels/CompileMetalKernels.swift")

        XCTAssertTrue(plugin.contains("-fdebug-prefix-map"))
        XCTAssertTrue(plugin.contains("-fdebug-compilation-dir=."))
        XCTAssertTrue(plugin.contains("-frecord-sources=no"))
        XCTAssertTrue(plugin.contains("source_copy="))
        XCTAssertTrue(plugin.contains("cp \"$f\" \"$source_copy\""))
        XCTAssertTrue(plugin.contains("cd \\(shellQuote(intermediatesDirectory.string))"))
    }

    func testReleasePackagerUsesNeutralScratchPathAndScansAppAndArchive() throws {
        let buildScript = try text("Scripts/build-app-bundle.sh")
        let packageScript = try text("Scripts/package-mac-release.sh")

        XCTAssertTrue(buildScript.contains("LUMAHARBOR_SCRATCH_PATH"))
        XCTAssertTrue(buildScript.contains("--scratch-path"))
        XCTAssertTrue(packageScript.contains("LUMAHARBOR_SCRATCH_PATH"))
        XCTAssertTrue(packageScript.contains("LUMAHARBOR_RELEASE_SCRATCH_PARENT:-/private/tmp"))
        XCTAssertTrue(packageScript.contains("LumaHarborReleaseBuild.XXXXXX"))
        XCTAssertGreaterThanOrEqual(
            packageScript.components(separatedBy: "verify-release-privacy.sh").count - 1,
            2
        )
        XCTAssertTrue(packageScript.contains("ditto -x -k"))
    }

    func testChecksumFileDoesNotRecordBuilderDirectory() throws {
        let packageScript = try text("Scripts/package-mac-release.sh")

        XCTAssertTrue(packageScript.contains(#"cd "${OUTPUT_DIR}""#))
        XCTAssertTrue(packageScript.contains(#"shasum -a 256 "${ARCHIVE_NAME}""#))
        XCTAssertTrue(packageScript.contains(#"verify-release-privacy.sh "${CHECKSUM_PATH}""#))
        XCTAssertFalse(packageScript.contains(#"shasum -a 256 "${ARCHIVE_PATH}""#))
    }

    func testPrivacyScannerFailsClosedForPrivateAbsolutePaths() throws {
        let scanner = url("Scripts/verify-release-privacy.sh")
        XCTAssertTrue(FileManager.default.fileExists(atPath: scanner.path))

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumaHarborReleasePrivacyTests-(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let cleanFile = root.appendingPathComponent("clean.txt")
        try Data("/private/tmp/LumaHarborReleaseBuild/resource.bundle".utf8).write(to: cleanFile)
        XCTAssertEqual(try runScanner(scanner, target: root), 0)

        let forbiddenPaths = [
            "/Users/private-builder/Projects/LumaHarbor",
            "/Volumes/Private Drive/LumaHarbor",
            "/home/private-builder/LumaHarbor",
        ]
        for path in forbiddenPaths {
            try Data(path.utf8).write(to: root.appendingPathComponent(UUID().uuidString))
            XCTAssertNotEqual(try runScanner(scanner, target: root), 0, "scanner accepted \(path)")
        }
    }

    private func runScanner(_ scanner: URL, target: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scanner.path, target.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
