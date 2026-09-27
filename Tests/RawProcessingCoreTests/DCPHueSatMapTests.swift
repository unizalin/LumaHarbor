import XCTest
@testable import RawProcessingCore

final class DCPHueSatMapTests: XCTestCase {
    func testUsesHueSaturationValueStorageOrder() throws {
        let dimensions = DCPTableDimensions(hue: 2, saturation: 2, value: 2)
        let samples = (0..<8).map { index in
            DCPHueSatSample(hueShift: Double(index) / 10, saturationScale: 1, valueScale: 1)
        }
        let map = try DCPHueSatMap(dimensions: dimensions, samples: samples)

        let sample = map.sample(hue: 0.5, saturation: 1, value: 1)

        XCTAssertEqual(sample.hueShift, 0.7, accuracy: 0.000_001)
    }

    func testHueInterpolationUsesShortestCircularPath() throws {
        let dimensions = DCPTableDimensions(hue: 2, saturation: 1, value: 1)
        let samples = [
            DCPHueSatSample(hueShift: 0.95, saturationScale: 1, valueScale: 1),
            DCPHueSatSample(hueShift: 0.05, saturationScale: 1, valueScale: 1)
        ]
        let map = try DCPHueSatMap(dimensions: dimensions, samples: samples)

        let sample = map.sample(hue: 0.99, saturation: 0, value: 0)

        XCTAssertEqual(sample.hueShift, 0.952, accuracy: 0.01)
    }

    func testSaturationAndValueCoordinatesClampToTableBounds() throws {
        let dimensions = DCPTableDimensions(hue: 1, saturation: 2, value: 2)
        let samples = [
            DCPHueSatSample(hueShift: 0, saturationScale: 1, valueScale: 10),
            DCPHueSatSample(hueShift: 0, saturationScale: 2, valueScale: 20),
            DCPHueSatSample(hueShift: 0, saturationScale: 3, valueScale: 30),
            DCPHueSatSample(hueShift: 0, saturationScale: 4, valueScale: 40)
        ]
        let map = try DCPHueSatMap(dimensions: dimensions, samples: samples)

        let sample = map.sample(hue: 0, saturation: 2, value: -1)

        XCTAssertEqual(sample.saturationScale, 3, accuracy: 0.000_001)
        XCTAssertEqual(sample.valueScale, 30, accuracy: 0.000_001)
    }

    func testIdentityTableLeavesNormalizedRGBUnchanged() throws {
        let map = try DCPHueSatMap(
            dimensions: DCPTableDimensions(hue: 1, saturation: 1, value: 1),
            samples: [DCPHueSatSample(hueShift: 0, saturationScale: 1, valueScale: 1)]
        )

        let output = try map.apply(to: [0.2, 0.4, 0.8])

        XCTAssertEqual(output.count, 3)
        for (actual, expected) in zip(output, [0.2, 0.4, 0.8]) {
            XCTAssertEqual(actual, expected, accuracy: 0.000_001)
        }
    }

    func testDualIlluminantBlendUsesShortestHuePath() throws {
        let dimensions = DCPTableDimensions(hue: 1, saturation: 1, value: 1)
        let first = try DCPHueSatMap(
            dimensions: dimensions,
            samples: [DCPHueSatSample(hueShift: 0.95, saturationScale: 1, valueScale: 1)]
        )
        let second = try DCPHueSatMap(
            dimensions: dimensions,
            samples: [DCPHueSatSample(hueShift: 0.05, saturationScale: 3, valueScale: 5)]
        )

        let blended = try DCPHueSatMap.blend(first, second, weight: 0.5)
        let sample = blended.sample(hue: 0, saturation: 0, value: 0)

        XCTAssertEqual(sample.hueShift, 0, accuracy: 0.000_001)
        XCTAssertEqual(sample.saturationScale, 2, accuracy: 0.000_001)
        XCTAssertEqual(sample.valueScale, 3, accuracy: 0.000_001)
    }

    func testRejectsMalformedDimensionsAndPayload() {
        XCTAssertThrowsError(
            try DCPHueSatMap(
                dimensions: DCPTableDimensions(hue: 0, saturation: 1, value: 1),
                samples: [DCPHueSatSample(hueShift: 0, saturationScale: 1, valueScale: 1)]
            )
        )
        XCTAssertThrowsError(
            try DCPHueSatMap(
                dimensions: DCPTableDimensions(hue: 2, saturation: 2, value: 2),
                samples: Array(repeating: DCPHueSatSample(hueShift: 0, saturationScale: 1, valueScale: 1), count: 7)
            )
        )
    }

    func testRejectsNonFiniteSamples() {
        XCTAssertThrowsError(
            try DCPHueSatMap(
                dimensions: DCPTableDimensions(hue: 1, saturation: 1, value: 1),
                samples: [DCPHueSatSample(hueShift: .nan, saturationScale: 1, valueScale: 1)]
            )
        )
    }

    func testReadsValidatedDimensionsAndPayloadFromProfileDocument() throws {
        let document = DCPProfileDocument(
            byteOrder: .littleEndian,
            tags: [
                DCPProfileTag.profileHueSatMapDims: .unsignedShort([1, 1, 1]),
                DCPProfileTag.profileHueSatMapData1: .signedRational([
                    DCPSignedRational(numerator: 0, denominator: 1),
                    DCPSignedRational(numerator: 1, denominator: 1),
                    DCPSignedRational(numerator: 1, denominator: 1)
                ])
            ]
        )

        let map = try DCPHueSatMap(document: document)
        XCTAssertEqual(map.sample(hue: 0, saturation: 0, value: 0), DCPHueSatSample(
            hueShift: 0,
            saturationScale: 1,
            valueScale: 1
        ))
    }
}
