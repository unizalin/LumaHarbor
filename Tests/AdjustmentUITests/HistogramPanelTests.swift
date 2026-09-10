import XCTest
@testable import AdjustmentUI
import RawProcessingCore

final class HistogramPanelTests: XCTestCase {
    func testLuminanceBinsUseTheRenderedRGBHistogram() {
        let histogram = HistogramData(
            red: [100, 0],
            green: [0, 100],
            blue: [0, 0]
        )

        let bins = HistogramPresentationMetrics.luminanceBins(histogram)

        XCTAssertEqual(bins, [21, 71])
    }

    func testClippingCountsExposeTheMostClippedChannelAtEachEndpoint() {
        let histogram = HistogramData(
            red: [4, 0, 9],
            green: [12, 0, 2],
            blue: [3, 0, 7]
        )

        let clipping = HistogramPresentationMetrics.clippingCounts(histogram)

        XCTAssertEqual(clipping.shadows, 12)
        XCTAssertEqual(clipping.highlights, 9)
    }
}
