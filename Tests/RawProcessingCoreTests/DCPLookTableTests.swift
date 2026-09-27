import XCTest
@testable import RawProcessingCore

final class DCPLookTableTests: XCTestCase {
    func testPerformsTrilinearInterpolationAcrossAllAxes() throws {
        let dimensions = DCPTableDimensions(hue: 2, saturation: 2, value: 2)
        let samples = (0..<8).map { index in
            DCPHueSatSample(
                hueShift: Double(index) / 100,
                saturationScale: Double(index),
                valueScale: Double(index)
            )
        }
        let table = try DCPLookTable(dimensions: dimensions, samples: samples)

        let sample = table.sample(hue: 0.25, saturation: 0.5, value: 0.5)

        XCTAssertEqual(sample.hueShift, 0.035, accuracy: 0.000_001)
        XCTAssertEqual(sample.saturationScale, 3.5, accuracy: 0.000_001)
        XCTAssertEqual(sample.valueScale, 3.5, accuracy: 0.000_001)
    }

    func testIdentityLookTableLeavesRGBUnchanged() throws {
        let table = try DCPLookTable(
            dimensions: DCPTableDimensions(hue: 1, saturation: 1, value: 1),
            samples: [DCPHueSatSample(hueShift: 0, saturationScale: 1, valueScale: 1)]
        )

        let output = try table.apply(to: [0.7, 0.3, 0.1])

        for (actual, expected) in zip(output, [0.7, 0.3, 0.1]) {
            XCTAssertEqual(actual, expected, accuracy: 0.000_001)
        }
    }

    func testBlendRejectsDifferentDimensionsAndInvalidWeight() throws {
        let first = try DCPLookTable(
            dimensions: DCPTableDimensions(hue: 1, saturation: 1, value: 1),
            samples: [DCPHueSatSample(hueShift: 0, saturationScale: 1, valueScale: 1)]
        )
        let second = try DCPLookTable(
            dimensions: DCPTableDimensions(hue: 2, saturation: 1, value: 1),
            samples: Array(repeating: DCPHueSatSample(hueShift: 0, saturationScale: 1, valueScale: 1), count: 2)
        )

        XCTAssertThrowsError(try DCPLookTable.blend(first, second, weight: 0.5))
        XCTAssertThrowsError(try DCPLookTable.blend(first, first, weight: 2))
    }

    func testRejectsMalformedLookTableSamples() {
        XCTAssertThrowsError(
            try DCPLookTable(
                dimensions: DCPTableDimensions(hue: 1, saturation: 1, value: 1),
                samples: [DCPHueSatSample(hueShift: 0, saturationScale: .infinity, valueScale: 1)]
            )
        )
    }

    func testReadsDimensionsAndPayloadFromProfileDocument() throws {
        let document = DCPProfileDocument(
            byteOrder: .littleEndian,
            tags: [
                DCPProfileTag.profileLookTableDims: .unsignedShort([1, 1, 1]),
                DCPProfileTag.profileLookTableData: .double([0, 1, 1])
            ]
        )

        let table = try DCPLookTable(document: document)
        XCTAssertEqual(table.sample(hue: 0, saturation: 0, value: 0), DCPHueSatSample(
            hueShift: 0,
            saturationScale: 1,
            valueScale: 1
        ))
    }
}
