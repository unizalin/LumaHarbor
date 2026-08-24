import Foundation
import XCTest
@testable import AdjustmentUI

final class BasicAdjustmentPanelModelTests: XCTestCase {
    func testRowsComeFromTheCanonicalAdjustmentCatalog() {
        XCTAssertEqual(BasicAdjustmentPanelModel.rows.count, 10)
        XCTAssertEqual(Set(BasicAdjustmentPanelModel.rows.map(\.kind.rawValue)).count, 10)
    }

    func testExposureIsFirstAndSaturationIsLast() {
        XCTAssertEqual(BasicAdjustmentPanelModel.rows.first?.kind, .exposure)
        XCTAssertEqual(BasicAdjustmentPanelModel.rows.last?.kind, .saturation)
    }

    func testPositiveValuesCarryAPlusSign() {
        XCTAssertEqual(BasicAdjustmentPanelModel.formatted(1.25, fractionDigits: 2), "+1.25")
        XCTAssertEqual(BasicAdjustmentPanelModel.formatted(0, fractionDigits: 0), "0")
    }

    func testMacResetGestureAndHelpRemainPlatformGuarded() throws {
        let panelSource = try panelSource()

        XCTAssertTrue(panelSource.contains("#if os(macOS)"))
        XCTAssertTrue(panelSource.contains(".onTapGesture(count: 2)"))
        XCTAssertTrue(panelSource.contains(".help(L10n.t(\"Double-click the row to reset\"))"))
    }

    func testViewUsesCanonicalRowsWithoutGroupReordering() throws {
        let panelSource = try panelSource()

        XCTAssertTrue(panelSource.contains("ForEach(BasicAdjustmentPanelModel.rows, id: \\.kind)"))
        XCTAssertFalse(panelSource.contains("AdjustmentGroup.allCases"))
        XCTAssertFalse(panelSource.contains("AdjustmentCatalog.definitions(in:"))
    }

    private func panelSource() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/AdjustmentUI/BasicAdjustmentPanel.swift"),
            encoding: .utf8
        )
    }
}
