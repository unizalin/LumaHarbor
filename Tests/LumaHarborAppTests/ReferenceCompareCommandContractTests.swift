import Foundation
import XCTest

final class ReferenceCompareCommandContractTests: XCTestCase {
    func testPackageDeclaresReferenceComparisonCommand() throws {
        let package = try String(contentsOf: repoRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
        XCTAssertTrue(package.contains("LumaHarborReferenceCompare"))
        XCTAssertTrue(package.contains(".executableTarget(name: \"LumaHarborReferenceCompare\""))
    }

    func testCommandLoadsImageIOCallsMetricsAndRedactsPaths() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/LumaHarborReferenceCompare/main.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("CGImageSourceCreateWithURL"))
        XCTAssertTrue(source.contains("ReferenceComparisonMetrics.compare"))
        XCTAssertTrue(source.contains("meanAbsoluteEffectError"))
        XCTAssertTrue(source.contains("NOT RUN"))
        XCTAssertFalse(source.contains("print(error.localizedDescription)"))
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
