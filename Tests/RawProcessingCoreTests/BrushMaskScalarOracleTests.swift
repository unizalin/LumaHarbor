import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import RawProcessingCore

/// Independent scalar oracle for the pre-tile stamp order. It deliberately
/// keeps the old `hypot` path separate from the production rasterizer so a
/// future optimization cannot make its own output the expected answer.
final class BrushMaskScalarOracleTests: XCTestCase {
    func testRepeatedGeometryStrokeCacheMatchesScalarOracle() throws {
        let extent = CGRect(x: 7, y: 11, width: 257, height: 259)
        let mapping = try BrushCoordinateMapping(sourceExtent: extent, geometry: .neutral)
        let points = [
            BrushMaskPoint(x: 0.12, y: 0.18),
            BrushMaskPoint(x: 0.82, y: 0.76)
        ]
        let masks = [
            BrushMaskStroke(points: points, mode: .paint, size: 0.74, feather: 0.25, flow: 0.61),
            BrushMaskStroke(points: points, mode: .erase, size: 0.74, feather: 0.25, flow: 0.61),
            BrushMaskStroke(points: points, mode: .paint, size: 0.74, feather: 0.25, flow: 0.61)
        ]
        let mask = BrushMask(strokes: masks, adjustments: BrushMaskPatch(exposure: 1))
        let expected = try scalarCoverage(mask, extent: extent, mapping: mapping)
        let actual = try BrushMaskRenderer._testRenderCoverageBytes(
            mask,
            imageExtent: extent,
            mapping: mapping
        )

        XCTAssertEqual(actual, expected.bytes)
    }

    func testTiledCoverageMatchesScalarOracleAcrossVerticalTileBoundaries() throws {
        let extents = [127, 128, 129, 240, 256, 257].map {
            CGRect(x: 0, y: 0, width: 180, height: $0)
        } + [
            CGRect(x: 7, y: 11, width: 257, height: 259),
            CGRect(x: -13, y: -5, width: 257, height: 259),
            CGRect(x: 7, y: 11, width: 1_600, height: 1_067)
        ]
        for extent in extents {
            let mapping = try BrushCoordinateMapping(sourceExtent: extent, geometry: .neutral)
            let mask = BrushMask(
                strokes: [
                    BrushMaskStroke(
                        points: [BrushMaskPoint(x: 0.13, y: 0.19)],
                        size: 0.08,
                        feather: 0.31,
                        flow: 0.73
                    )
                ],
                adjustments: BrushMaskPatch(exposure: 1)
            )

            let expected = try scalarCoverage(mask, extent: extent, mapping: mapping)
            let actualBytes = try BrushMaskRenderer._testRenderCoverageBytes(
                mask,
                imageExtent: extent,
                mapping: mapping
            )

            XCTAssertEqual(
                actualBytes,
                expected.bytes,
                "R8 coverage must preserve global row mapping for extent \(extent)"
            )
        }
    }

    func testSyncAndAsyncCompositionMatchIndependentThreeMaskOracle() async throws {
        let extent = CGRect(x: 7, y: 11, width: 257, height: 259)
        let source = CIImage(color: CIColor(red: 0.35, green: 0.48, blue: 0.62)).cropped(to: extent)
        let mapping = try BrushCoordinateMapping(sourceExtent: extent, geometry: .neutral)
        let masks = [
            BrushMask(
                strokes: [BrushMaskStroke(
                    points: [BrushMaskPoint(x: 0.18, y: 0.22), BrushMaskPoint(x: 0.78, y: 0.72)],
                    size: 0.24,
                    feather: 0.3,
                    flow: 0.72
                )],
                adjustments: BrushMaskPatch(exposure: 0.65)
            ),
            BrushMask(
                strokes: [
                    BrushMaskStroke(
                        points: [BrushMaskPoint(x: 0.24, y: 0.68), BrushMaskPoint(x: 0.76, y: 0.28)],
                        size: 0.22,
                        feather: 1,
                        flow: 0.81
                    ),
                    BrushMaskStroke(
                        points: [BrushMaskPoint(x: 0.54, y: 0.48)],
                        mode: .erase,
                        size: 0.04,
                        feather: 0,
                        flow: 0.6
                    )
                ],
                adjustments: BrushMaskPatch(contrast: 18)
            ),
            BrushMask(
                strokes: [BrushMaskStroke(
                    points: [BrushMaskPoint(x: 0.5, y: 0.2), BrushMaskPoint(x: 0.5, y: 0.82)],
                    size: 0.18,
                    feather: 0.15,
                    flow: 0.55
                )],
                adjustments: BrushMaskPatch(blacks: 0.2)
            )
        ]

        var expected = source
        for mask in masks {
            let coverage = try scalarCoverage(mask, extent: extent, mapping: mapping).image
            let adjusted = AdjustmentPipeline().apply(
                parameters(for: mask.adjustments),
                to: expected,
                recipe: nil,
                scaleFactor: 1
            )
            let blend = CIFilter.blendWithMask()
            blend.inputImage = adjusted.cropped(to: extent)
            blend.backgroundImage = expected
            blend.maskImage = coverage
            expected = try XCTUnwrap(blend.outputImage).cropped(to: extent)
        }

        let sync = try BrushMaskRenderer.applyValidated(masks, to: source, mapping: mapping)
        let asyncImage = try await BrushMaskRenderer.applyValidatedAsync(masks, to: source, mapping: mapping)
        let service = ImageRenderService(preferMetal: false)
        let expectedPixels = try XCTUnwrap(service.makeCGImage(expected).dataProvider?.data as Data?)
        let syncPixels = try XCTUnwrap(service.makeCGImage(sync).dataProvider?.data as Data?)
        let asyncPixels = try XCTUnwrap(service.makeCGImage(asyncImage).dataProvider?.data as Data?)

        XCTAssertLessThanOrEqual(maximumByteDifference(expectedPixels, syncPixels), 1)
        XCTAssertLessThanOrEqual(maximumByteDifference(expectedPixels, asyncPixels), 1)
    }

    func testTiledCoverageMatchesIndependentScalarOracle() throws {
        let extent = CGRect(x: 7, y: 11, width: 180, height: 120)
        let source = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: extent)
        let mapping = try BrushCoordinateMapping(sourceExtent: extent, geometry: .neutral)
        let mask = BrushMask(
            strokes: [
                BrushMaskStroke(
                    points: [
                        BrushMaskPoint(x: 0.17, y: 0.23),
                        BrushMaskPoint(x: 0.78, y: 0.23),
                        BrushMaskPoint(x: 0.78, y: 0.81)
                    ],
                    size: 0.16,
                    feather: 0.35,
                    flow: 0.62
                ),
                BrushMaskStroke(
                    points: [BrushMaskPoint(x: 0.55, y: 0.43)],
                    mode: .erase,
                    size: 0.08,
                    feather: 0.1,
                    flow: 0.7
                )
            ],
            adjustments: BrushMaskPatch(exposure: 1.25)
        )

        let expectedCoverage = try scalarCoverage(mask, extent: extent, mapping: mapping).image
        let adjusted = AdjustmentPipeline().apply(PhotoAdjustments(exposure: 1.25), to: source)
        let expectedBlend = CIFilter.blendWithMask()
        expectedBlend.inputImage = adjusted.cropped(to: extent)
        expectedBlend.backgroundImage = source
        expectedBlend.maskImage = expectedCoverage
        let expected = try XCTUnwrap(expectedBlend.outputImage).cropped(to: extent)

        let actual = try BrushMaskRenderer.applyValidated([mask], to: source, mapping: mapping)
        let service = ImageRenderService(preferMetal: false)
        let expectedPixels = try XCTUnwrap(service.makeCGImage(expected).dataProvider?.data as Data?)
        let actualPixels = try XCTUnwrap(service.makeCGImage(actual).dataProvider?.data as Data?)

        XCTAssertEqual(expectedPixels.count, actualPixels.count)
        let maximumDifference = zip(expectedPixels, actualPixels)
            .map { abs(Int($0) - Int($1)) }
            .max() ?? 0
        XCTAssertLessThanOrEqual(maximumDifference, 0)
    }

    func testAsyncCompositionMatchesSynchronousEntry() async throws {
        let extent = CGRect(x: 0, y: 0, width: 96, height: 64)
        let source = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: extent)
        let masks = [
            BrushMask(
                strokes: [BrushMaskStroke(
                    points: [BrushMaskPoint(x: 0.2, y: 0.2), BrushMaskPoint(x: 0.8, y: 0.7)],
                    size: 0.13,
                    feather: 0.2,
                    flow: 0.7
                )],
                adjustments: BrushMaskPatch(exposure: 0.5)
            ),
            BrushMask(
                strokes: [BrushMaskStroke(
                    points: [BrushMaskPoint(x: 0.65, y: 0.35)],
                    mode: .erase,
                    size: 0.09,
                    feather: 0.1,
                    flow: 0.8
                )],
                adjustments: BrushMaskPatch(blacks: 0.2)
            )
        ]
        let sync = try BrushMaskRenderer.applyValidated(masks, to: source)
        let asyncImage = try await BrushMaskRenderer.applyValidatedAsync(masks, to: source)
        let service = ImageRenderService(preferMetal: false)
        let syncPixels = try XCTUnwrap(service.makeCGImage(sync).dataProvider?.data as Data?)
        let asyncPixels = try XCTUnwrap(service.makeCGImage(asyncImage).dataProvider?.data as Data?)

        XCTAssertEqual(syncPixels, asyncPixels)
    }

    private func scalarCoverage(
        _ mask: BrushMask,
        extent: CGRect,
        mapping: BrushCoordinateMapping
    ) throws -> (image: CIImage, bytes: Data) {
        let width = Int(extent.width.rounded(.up))
        let height = Int(extent.height.rounded(.up))
        var alpha = [CGFloat](repeating: 0, count: width * height)
        let shortSide = min(extent.width, extent.height)

        for stroke in mask.strokes {
            let points = try stroke.validated().points
            guard !points.isEmpty, stroke.flow > 0 else { continue }
            let samples = try scalarSamples(points: points, stroke: stroke, mapping: mapping)
            for point in samples {
                let feather = min(max(CGFloat(stroke.feather), 0), 1)
                let radius = max(CGFloat(stroke.size) * shortSide / 2 * (1 + feather), 0.5)
                let innerRadius = radius * (1 - feather)
                let visualY = extent.maxY - (point.y - extent.minY)
                let minX = max(0, Int(floor(point.x - radius - extent.minX - 1)))
                let maxX = min(width - 1, Int(ceil(point.x + radius - extent.minX + 1)))
                let minY = max(0, Int(floor(visualY - radius - extent.minY - 1)))
                let maxY = min(height - 1, Int(ceil(visualY + radius - extent.minY + 1)))
                guard minX <= maxX, minY <= maxY else { continue }
                for y in minY...maxY {
                    for x in minX...maxX {
                        let world = CGPoint(
                            x: extent.minX + CGFloat(x) + 0.5,
                            y: extent.minY + CGFloat(y) + 0.5
                        )
                        let distance = hypot(world.x - point.x, world.y - visualY)
                        let opacity = distance <= innerRadius
                            ? CGFloat(stroke.flow)
                            : (distance < radius
                                ? CGFloat(stroke.flow) * (1 - (distance - innerRadius) / max(radius - innerRadius, 0.0001))
                                : 0)
                        guard opacity > 0 else { continue }
                        let index = y * width + x
                        alpha[index] = stroke.mode == .paint
                            ? 1 - (1 - alpha[index]) * (1 - opacity)
                            : alpha[index] * (1 - opacity)
                    }
                }
            }
        }

        let bytes = (0..<height).flatMap { row in
            let sourceRow = height - 1 - row
            return (0..<width).map { x in
                UInt8((min(max(alpha[sourceRow * width + x], 0), 1) * 255).rounded())
            }
        }
        let gray = CGColorSpace(name: CGColorSpace.linearGray) ?? CGColorSpaceCreateDeviceGray()
        let bitmap = Data(bytes)
        let image = CIImage(
            bitmapData: bitmap,
            bytesPerRow: width,
            size: CGSize(width: width, height: height),
            format: .R8,
            colorSpace: gray
        )
        .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        .cropped(to: extent)
        return (image, bitmap)
    }

    private func scalarSamples(
        points: [BrushMaskPoint],
        stroke: BrushMaskStroke,
        mapping: BrushCoordinateMapping
    ) throws -> [CGPoint] {
        guard let first = points.first else { return [] }
        let firstPoint = try mapping.sourceToSourcePixel(first)
        var output = [firstPoint]
        let spacing = max(stroke.size / 8, 1 / min(mapping.sourceExtent.width, mapping.sourceExtent.height))
        var remaining = 0.0
        var previous = firstPoint
        for point in points.dropFirst() {
            let current = try mapping.sourceToSourcePixel(point)
            let dx = Double(current.x - previous.x)
            let dy = Double(current.y - previous.y)
            let segment = (dx * dx + dy * dy).squareRoot() / Double(min(mapping.displayExtent.width, mapping.displayExtent.height))
            guard segment.isFinite, segment > 0 else { continue }
            var travelled = remaining
            while travelled <= segment + 1e-12 {
                let t = travelled / segment
                output.append(CGPoint(
                    x: previous.x + CGFloat(t) * (current.x - previous.x),
                    y: previous.y + CGFloat(t) * (current.y - previous.y)
                ))
                travelled += spacing
            }
            remaining = travelled - segment
            previous = current
        }
        if output.last != previous { output.append(previous) }
        return output
    }

    private func parameters(for patch: BrushMaskPatch) -> PhotoAdjustments {
        var adjustments = PhotoAdjustments.neutral
        if let value = patch.exposure { adjustments.exposure = value }
        if let value = patch.contrast { adjustments.contrast = value }
        if let value = patch.highlights { adjustments.highlights = value }
        if let value = patch.shadows { adjustments.shadows = value }
        if let value = patch.whites { adjustments.whites = value }
        if let value = patch.blacks { adjustments.blacks = value }
        if let value = patch.saturation { adjustments.saturation = value }
        if let value = patch.temperature { adjustments.temperature = value }
        if let value = patch.tint { adjustments.tint = value }
        return adjustments
    }

    private func maximumByteDifference(_ lhs: Data, _ rhs: Data) -> Int {
        guard lhs.count == rhs.count else { return .max }
        return zip(lhs, rhs).map { abs(Int($0) - Int($1)) }.max() ?? 0
    }
}
