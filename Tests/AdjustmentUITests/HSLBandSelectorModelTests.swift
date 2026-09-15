import XCTest
@testable import AdjustmentUI
import RawProcessingCore

/// Inspector hierarchy/typography spec (2026-09-14) §5.2: the HSL and
/// black-and-white color mixers replace their eight nested `DisclosureGroup`
/// bands with one adaptive grid selector plus a single active band editor.
/// Pure model -- column count and selection are plain data, independent of
/// any SwiftUI rendering.
final class HSLBandSelectorModelTests: XCTestCase {
    func testExposesAllEightBands() {
        XCTAssertEqual(HSLBandSelectorModel.allBands.count, 8)
        XCTAssertEqual(
            Set(HSLBandSelectorModel.allBands.map(\.id)),
            Set(["red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta"])
        )
    }

    func testDefaultsToTheFirstBand() {
        XCTAssertEqual(HSLBandSelectorModel.allBands.first?.id, "red")
    }

    func testFourColumnsAtOrAbove340Points() {
        XCTAssertEqual(HSLBandSelectorModel.columnCount(forAvailableWidth: 340), 4)
        XCTAssertEqual(HSLBandSelectorModel.columnCount(forAvailableWidth: 600), 4)
    }

    func testTwoColumnsBelow340Points() {
        XCTAssertEqual(HSLBandSelectorModel.columnCount(forAvailableWidth: 339.9), 2)
        XCTAssertEqual(HSLBandSelectorModel.columnCount(forAvailableWidth: 200), 2)
    }

    /// Selecting a band is presentation-only -- it must never look like an
    /// edit to `PhotoAdjustments`, and there is nothing in this model that
    /// could touch history, sidecar, or render state (spec §5.2: "changing
    /// the selected band must not render the photo, write history, save the
    /// sidecar, or reset any values").
    func testIsModifiedReflectsWhetherTheBandsFieldsAreAllZero() {
        var hsl = HSLAdjustments()
        XCTAssertFalse(HSLBandSelectorModel.isModified(.red, in: hsl))

        hsl.red.hue = 10
        XCTAssertTrue(HSLBandSelectorModel.isModified(.red, in: hsl))
        XCTAssertFalse(HSLBandSelectorModel.isModified(.orange, in: hsl))
    }
}
