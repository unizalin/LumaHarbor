import XCTest
@testable import AdjustmentUI

final class BasicAdjustmentPanelModelTests: XCTestCase {
    func testRowsComeFromTheCanonicalAdjustmentCatalog() {
        XCTAssertEqual(BasicAdjustmentPanelModel.rows.count, 10)
        XCTAssertEqual(Set(BasicAdjustmentPanelModel.rows.map(\.kind.rawValue)).count, 10)
    }
}
