import XCTest
import EditorCore
@testable import AdjustmentUI

/// P2 (design spec §7.1 "Smart Follow"): switching the canvas gesture tool must
/// navigate the inspector to the matching section, driven off the already-existing
/// `EditorToolMode` (crop/whiteBalance/linearGradient/spotHeal) -- not a new,
/// parallel selection concept.
final class InspectorSmartFollowTests: XCTestCase {

    func testCropFollowsToGeometry() {
        XCTAssertEqual(InspectorSmartFollow.section(for: .crop), .geometry)
    }

    func testWhiteBalanceFollowsToWhiteBalanceSection() {
        XCTAssertEqual(InspectorSmartFollow.section(for: .whiteBalance), .whiteBalance)
    }

    func testLinearGradientFollowsToLocal() {
        XCTAssertEqual(InspectorSmartFollow.section(for: .linearGradient), .local)
    }

    func testSpotHealFollowsToLocal() {
        XCTAssertEqual(InspectorSmartFollow.section(for: .spotHeal), .local)
    }

    func testAdjustModeDoesNotFollow() {
        XCTAssertNil(InspectorSmartFollow.section(for: .adjust), "the generic adjust tool must not force a section switch")
    }
}
