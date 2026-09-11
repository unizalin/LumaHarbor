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

    func testDisplayHeightsUseLogCompressionForDominantClippingSpikes() {
        let heights = HistogramPresentationMetrics.displayHeights(for: [240_446, 16, 1])

        XCTAssertEqual(heights.count, 3)
        XCTAssertEqual(heights[0], 1, accuracy: 0.0001)
        XCTAssertGreaterThan(heights[1], 0.2)
        XCTAssertGreaterThan(heights[2], 0)
        XCTAssertGreaterThan(heights[1], heights[2])
    }

    func testDisplayHeightsSanitizeNegativeAndEmptyBins() {
        XCTAssertEqual(HistogramPresentationMetrics.displayHeights(for: []), [])
        let heights = HistogramPresentationMetrics.displayHeights(for: [-10, 0, 10])
        XCTAssertEqual(heights.count, 3)
        XCTAssertEqual(heights[0], 0, accuracy: 0.0001)
        XCTAssertEqual(heights[1], 0, accuracy: 0.0001)
        XCTAssertEqual(heights[2], 1, accuracy: 0.0001)
    }
}
