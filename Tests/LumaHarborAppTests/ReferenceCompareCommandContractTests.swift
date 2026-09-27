import Foundation
import XCTest

final class ReferenceCompareCommandContractTests: XCTestCase {
    func testPackageDeclaresReferenceComparisonCommand() throws {
        let package = try String(contentsOf: repoRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
        XCTAssertTrue(package.contains("LumaHarborReferenceCompare"))
        XCTAssertTrue(package.contains(".executableTarget(name: \"LumaHarborReferenceCompare\""))
    }

    func testCommandUsesTypedSixteenBitBufferAndRedactsPaths() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/LumaHarborReferenceCompare/main.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("ReferenceImageTileReader(url:"))
        XCTAssertTrue(source.contains("ReferenceComparisonMetrics.compareStreaming"))
        XCTAssertTrue(source.contains("let mode: ReferenceComparisonMode"))
        XCTAssertTrue(source.contains("let meanAbsoluteError: Double"))
        XCTAssertTrue(source.contains("let p95AbsoluteError: Double"))
        XCTAssertTrue(source.contains("let luminanceSSIM: Double"))
        XCTAssertTrue(source.contains("highlightClippingFractionDelta"))
        XCTAssertTrue(source.contains("shadowClippingFractionDelta"))
        XCTAssertTrue(source.contains("ReferenceComparisonMode(rawValue:"))
        XCTAssertTrue(source.contains("parsed.values[\"--mode\"]"))
        XCTAssertTrue(source.contains("--all-neutral"))
        XCTAssertTrue(source.contains("NOT RUN"))
        XCTAssertFalse(source.contains("print(error.localizedDescription)"))
    }

    func testCommandRejectsAmbiguousReferenceImageCandidates() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/LumaHarborReferenceCompare/main.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("ReferenceImageLocator.resolve"))
        XCTAssertTrue(source.contains("case ambiguousImage"))
        XCTAssertTrue(source.contains("ambiguous reference image"))
    }

    func testCommandUsesVersionedThresholdsAndEmitsPerMetricEvaluation() throws {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/LumaHarborReferenceCompare/main.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("LightroomReferenceThresholds.current"))
        XCTAssertTrue(source.contains("thresholds.version"))
        XCTAssertTrue(source.contains("let meanAbsoluteErrorPassed: Bool"))
        XCTAssertTrue(source.contains("let p95AbsoluteErrorPassed: Bool"))
        XCTAssertTrue(source.contains("let luminanceSSIMPassed: Bool"))
        XCTAssertTrue(source.contains("isPassing"))
        XCTAssertFalse(source.contains("private let meanErrorThreshold"))
        XCTAssertFalse(source.contains("private let p95ErrorThreshold"))
        XCTAssertFalse(source.contains("private let ssimThreshold"))
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
