import XCTest
@testable import AdjustmentUI
import RawProcessingCore

final class PadExportOptionsTests: XCTestCase {
    func testQualityPercentageClampsToEncoderRange() {
        var options = PadExportOptions()
        options.qualityPercentage = 140
        XCTAssertEqual(options.quality, 1)
        options.qualityPercentage = -20
        XCTAssertEqual(options.quality, 0)
    }

    func testMaximumDimensionAndDPIAreBounded() {
        var options = PadExportOptions()
        options.setMaximumDimension(10)
        XCTAssertEqual(options.maximumDimension, 256)
        options.setMaximumDimension(200_000)
        XCTAssertEqual(options.maximumDimension, 100_000)
        options.setDPI(0)
        XCTAssertEqual(options.dpi, 1)
        options.setDPI(3_000)
        XCTAssertEqual(options.dpi, 2_400)
    }

    func testRequestMapsTIFFBitDepthAndMaximumDimension() {
        var options = PadExportOptions()
        options.format = .tiff
        options.bitDepth = .sixteenBit
        options.setMaximumDimension(4_000)
        options.setDPI(300)

        let request = options.request(
            sourceURL: URL(fileURLWithPath: "/tmp/input.ARW"),
            adjustments: .neutral,
            destinationDirectory: URL(fileURLWithPath: "/tmp/out", isDirectory: true),
            baseFilename: "input"
        )

        XCTAssertEqual(request.format, .tiff)
        XCTAssertEqual(request.bitDepth, .sixteenBit)
        XCTAssertEqual(request.maximumWidth, 4_000)
        XCTAssertEqual(request.maximumHeight, 4_000)
        XCTAssertEqual(request.dpi, 300)
    }

    func testNonTIFFFormatsUseEightBitRegardlessOfStaleSelection() {
        var options = PadExportOptions()
        options.format = .jpeg
        options.bitDepth = .sixteenBit
        let request = options.request(
            sourceURL: URL(fileURLWithPath: "/tmp/input.ARW"),
            adjustments: .neutral,
            destinationDirectory: URL(fileURLWithPath: "/tmp/out", isDirectory: true),
            baseFilename: "input"
        )
        XCTAssertEqual(request.bitDepth, .eightBit)
    }
}
