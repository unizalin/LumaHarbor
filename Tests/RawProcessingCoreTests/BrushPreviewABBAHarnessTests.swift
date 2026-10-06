import CoreGraphics
import CoreImage
import Darwin
import Foundation
import XCTest
@testable import RawProcessingCore

/// One production-preview sample per process. The shell orchestrator controls
/// B/O order so compiler work and another variant never overlap a timed sample.
final class BrushPreviewABBAHarnessTests: XCTestCase {
    func testChangedScenarioKeepsEmptyControlNeutralAcrossOrdinals() {
        for ordinal in 0..<16 {
            let empty = makeInputs(scenario: "changed", maskCount: 0, sampleOrdinal: ordinal)
            XCTAssertEqual(empty.timed.exposure, 0, "empty control must stay neutral")
            XCTAssertEqual(empty.warmup?.exposure, 0)
            for count in [1, 10] {
                let active = makeInputs(scenario: "changed", maskCount: count, sampleOrdinal: ordinal)
                XCTAssertEqual(active.timed.exposure, ordinal.isMultiple(of: 2) ? 0.05 : -0.05)
                XCTAssertEqual(active.timed.brushMasks.count, count)
            }
        }
    }

    func testOptInProductionPreviewSample() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LUMAHARBOR_RUN_BRUSH_ABBA"] == "1" else {
            throw XCTSkip("brush B/O ABBA acceptance is opt-in")
        }
        let variant = try XCTUnwrap(environment["LUMAHARBOR_BRUSH_VARIANT"])
        let productSHA = try XCTUnwrap(environment["LUMAHARBOR_BRUSH_PRODUCT_SHA"])
        let harnessSHA = try XCTUnwrap(environment["LUMAHARBOR_BRUSH_HARNESS_SHA"])
        let instrumentationDigest = try XCTUnwrap(environment["LUMAHARBOR_BRUSH_INSTRUMENTATION_DIGEST"])
        let round = Int(environment["LUMAHARBOR_BRUSH_ROUND"] ?? "") ?? 0
        let order = Int(environment["LUMAHARBOR_BRUSH_ORDER"] ?? "") ?? 0
        let sampleOrdinal = Int(environment["LUMAHARBOR_BRUSH_SAMPLE_ORDINAL"] ?? "") ?? 0
        let maskCount = Int(environment["LUMAHARBOR_BRUSH_MASK_COUNT"] ?? "") ?? 0
        let scenario = try XCTUnwrap(environment["LUMAHARBOR_BRUSH_SCENARIO"])
        XCTAssertTrue([0, 1, 10].contains(maskCount))
        XCTAssertTrue(["cold", "warm", "changed", "appended", "stress"].contains(scenario))

        let decoder = SyntheticRawDecoder(pixelSize: CGSize(width: 1_600, height: 1_067))
        let renderer = CoreImagePreviewRenderer(
            decoder: decoder,
            renderService: ImageRenderService(preferMetal: true)
        )
        let inputs = makeInputs(scenario: scenario, maskCount: maskCount, sampleOrdinal: sampleOrdinal)
        let request = PreviewRequest(
            subject: PreviewSubject(UUID(uuidString: "00000000-0000-4000-8000-000000000001")!),
            url: URL(fileURLWithPath: "/tmp/brush-abba-synthetic.raw"),
            adjustments: inputs.timed,
            targetPixelDimension: 1_600,
            quality: .interactive
        )

        if let warmup = inputs.warmup {
            _ = try await renderer.render(PreviewRequest(
                subject: request.subject,
                url: request.url,
                adjustments: warmup,
                targetPixelDimension: request.targetPixelDimension,
                quality: request.quality
            ))
        }
        let clock = ContinuousClock()
        let start = clock.now
        let image = try await renderer.render(request)
        let total = seconds(start.duration(to: clock.now))
        XCTAssertGreaterThan(image.pixelSize.width, 0)
        XCTAssertGreaterThan(image.pixelSize.height, 0)

        let null = NSNull()
        let size: [String: Int] = ["width": 1_600, "height": 1_067]
        let outputSize: [String: Int] = [
            "width": Int(image.pixelSize.width),
            "height": Int(image.pixelSize.height)
        ]
        let scenarioName = scenarioName(scenario)
        let rssBytes = peakRSSBytes
        var unavailableReasons = [
            "recipeIDs": "synthetic decoder uses the native default recipe",
            "pixelError": "verified outside timed sample",
            "workerCounts": "observer disabled during timed sample",
            "cancelOutcome": "not a cancellation scenario",
            "stageDurationsSeconds": "public B/O production API exposes only total wall time"
        ]
        if rssBytes == nil {
            unavailableReasons["rssBytes"] = "getrusage failed for the isolated test process"
        }
        let record: [String: Any] = [
            "schemaVersion": 2,
            "productSHA": productSHA,
            "harnessSHA": harnessSHA,
            "instrumentationDigest": instrumentationDigest,
            "configuration": "release",
            "defines": [],
            "scenario": scenarioName,
            "variant": variant,
            "round": round,
            "order": order,
            "sampleOrdinal": sampleOrdinal,
            "seed": "LH-BRUSH-PERF-ACCEPTANCE-20261006",
            "maskCount": maskCount,
            "nativeSize": size,
            "decodedSize": size,
            "outputSize": outputSize,
            "recipeIDs": [],
            "stageDurationsSeconds": ["total": total],
            "totalDurationSeconds": total,
            "pixelError": null,
            "workerCounts": null,
            "cancelOutcome": null,
            "rssBytes": rssBytes.map { $0 as Any } ?? null,
            "thermalState": thermalStateName,
            "result": "MEASURED",
            "unavailableReasons": unavailableReasons
        ]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    private var thermalStateName: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private var peakRSSBytes: Int64? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        return Int64(usage.ru_maxrss)
    }

    private func scenarioName(_ scenario: String) -> String {
        switch scenario {
        case "cold": return "cold-first-open-production-preview"
        case "warm": return "warm-unchanged-production-preview"
        case "changed": return "parameter-changed-production-preview"
        case "appended": return "stroke-appended-production-preview"
        case "stress": return "stress-vectors-production-preview"
        default: return "invalid"
        }
    }

    private func makeInputs(
        scenario: String,
        maskCount: Int,
        sampleOrdinal: Int
    ) -> (warmup: PhotoAdjustments?, timed: PhotoAdjustments) {
        let baseMasks = makeMasks(count: maskCount)
        let base = PhotoAdjustments(brushMasks: baseMasks)
        switch scenario {
        case "cold":
            return (nil, base)
        case "warm":
            return (base, base)
        case "changed":
            let exposure = maskCount == 0 ? 0 : (sampleOrdinal.isMultiple(of: 2) ? 0.05 : -0.05)
            return (base, PhotoAdjustments(exposure: exposure, brushMasks: baseMasks))
        case "appended":
            guard !baseMasks.isEmpty else { return (base, base) }
            var appendedMasks = baseMasks
            appendedMasks[0].strokes.append(BrushMaskStroke(
                id: UUID(uuidString: "00000000-0000-4000-a000-000000000001")!,
                points: [
                    BrushMaskPoint(x: 0.15, y: 0.35, pressure: 0.65),
                    BrushMaskPoint(x: 0.85, y: 0.65, pressure: 0.65)
                ],
                size: 0.018,
                feather: 0.25,
                flow: 0.6,
                density: 0.8
            ))
            return (base, PhotoAdjustments(brushMasks: appendedMasks))
        case "stress":
            let geometry = GeometryAdjustments(
                straightenDegrees: 2,
                perspectiveHorizontal: 3,
                perspectiveVertical: -2
            )
            let stress = PhotoAdjustments(geometry: geometry, brushMasks: makeStressMasks(from: baseMasks))
            return (stress, stress)
        default:
            return (nil, base)
        }
    }

    private func makeStressMasks(from masks: [BrushMask]) -> [BrushMask] {
        masks.enumerated().map { maskIndex, mask in
            var copy = mask
            let points = [
                BrushMaskPoint(x: 0.1, y: 0.2, pressure: 1),
                BrushMaskPoint(x: 0.9, y: 0.8, pressure: 1)
            ]
            for (strokeIndex, mode) in [BrushMaskStrokeMode.paint, .erase, .paint].enumerated() {
                copy.strokes.append(BrushMaskStroke(
                    id: UUID(uuidString: String(
                        format: "00000000-0000-4000-b%03d-%012d",
                        maskIndex,
                        strokeIndex + 1
                    ))!,
                    points: points,
                    mode: mode,
                    size: 1,
                    feather: 0.25,
                    flow: 0.6,
                    density: 0.8
                ))
            }
            return copy
        }
    }

    private func makeMasks(count: Int) -> [BrushMask] {
        (0..<count).map { maskIndex in
            let strokes = (0..<10).map { strokeIndex in
                let points = (0..<100).map { pointIndex in
                    BrushMaskPoint(
                        x: 0.05 + 0.009 * Double(pointIndex),
                        y: 0.08 + Double((10 * maskIndex + strokeIndex) % 84) / 100,
                        pressure: 0.65
                    )
                }
                return BrushMaskStroke(
                    id: UUID(uuidString: String(
                        format: "00000000-0000-4000-8000-%012d",
                        strokeIndex + maskIndex * 10 + 1
                    ))!,
                    points: points,
                    size: 0.018,
                    feather: 0.25,
                    flow: 0.6,
                    density: 0.8
                )
            }
            return BrushMask(
                id: UUID(uuidString: String(
                    format: "00000000-0000-4000-9000-%012d",
                    maskIndex + 1
                ))!,
                name: "benchmark-\(maskIndex)",
                strokes: strokes,
                adjustments: BrushMaskPatch(exposure: maskIndex.isMultiple(of: 2) ? 0.25 : -0.2)
            )
        }
    }
}
