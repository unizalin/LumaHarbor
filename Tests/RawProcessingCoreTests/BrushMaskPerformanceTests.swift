import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import RawProcessingCore

/// Deterministic, opt-in workload for the brush rasterizer. The default unit
/// test only checks the fixture contract so ordinary CI remains bounded; the
/// timed path is enabled by `LUMAHARBOR_RUN_BRUSH_PERF_ACCEPTANCE=1` and is
/// the input to the checked-in acceptance script.
final class BrushMaskPerformanceTests: XCTestCase {
    private let width = 1_600
    private let height = 1_067

    func testWorkloadGeneratorIsDeterministic() throws {
        let masks = makeMasks(count: 10)

        XCTAssertEqual(masks.count, 10)
        XCTAssertEqual(masks[0].strokes.count, 10)
        XCTAssertEqual(masks[0].strokes[0].points.count, 100)
        XCTAssertEqual(masks[0].strokes[0].points.first, BrushMaskPoint(x: 0.05, y: 0.08, pressure: 0.65))
        let finalPoint = try XCTUnwrap(masks[9].strokes[9].points.last)
        XCTAssertEqual(finalPoint.x, 0.941, accuracy: 1e-12)
        XCTAssertEqual(finalPoint.y, 0.23, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(finalPoint.pressure), 0.65, accuracy: 1e-12)
        XCTAssertEqual(masks[0].adjustments.exposure, 0.25)
        XCTAssertEqual(masks[1].adjustments.exposure, -0.2)
    }

    func testOptInWorkloadPrintsMachineReadableSamples() async throws {
        guard ProcessInfo.processInfo.environment["LUMAHARBOR_RUN_BRUSH_PERF_ACCEPTANCE"] == "1" else {
            throw XCTSkip("brush performance acceptance is opt-in")
        }

        let sampleCount = max(
            Int(ProcessInfo.processInfo.environment["LUMAHARBOR_BRUSH_PERF_SAMPLES"] ?? "8") ?? 8,
            1
        )
        let source = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        let preferMetal = ProcessInfo.processInfo.environment["LUMAHARBOR_BRUSH_PERF_PREFER_METAL"] != "0"
        let service = ImageRenderService(preferMetal: preferMetal)
        let clock = ContinuousClock()

        for maskCount in [0, 1, 10] {
            let masks = makeMasks(count: maskCount)
            _ = try await render(masks, source: source, service: service)

            var coverageSamples: [Double] = []
            var samples: [Double] = []
            for _ in 0..<sampleCount {
                let coverageStart = clock.now
                try await renderCoverageInParallel(masks, extent: source.extent)
                let coverageDuration = coverageStart.duration(to: clock.now)
                coverageSamples.append(
                    Double(coverageDuration.components.seconds)
                        + Double(coverageDuration.components.attoseconds) / 1e18
                )

                let start = clock.now
                _ = try await render(masks, source: source, service: service)
                let duration = start.duration(to: clock.now)
                samples.append(
                    Double(duration.components.seconds)
                        + Double(duration.components.attoseconds) / 1e18
                )
            }

            let record: [String: Any] = [
                "schemaVersion": 1,
                "scenario": "synthetic-1600px",
                "maskCount": maskCount,
                "width": width,
                "height": height,
                "strokeCountPerMask": 10,
                "pointCountPerStroke": 100,
                "sampleCount": samples.count,
                "coverageDurationsSeconds": coverageSamples,
                "durationsSeconds": samples,
                "preferMetal": preferMetal,
                "seed": "LH-BRUSH-PERF-ACCEPTANCE-20261006"
            ]
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        }
    }

    private func render(
        _ masks: [BrushMask],
        source: CIImage,
        service: ImageRenderService
    ) async throws -> CGImage {
        let rendered = try await BrushMaskRenderer.applyValidatedAsync(masks, to: source)
        return try service.makeCGImage(rendered)
    }

    private func renderCoverageInParallel(_ masks: [BrushMask], extent: CGRect) async throws {
        if masks.count == 1, let mask = masks.first {
            _ = try BrushMaskRenderer._testRenderCoverage(mask, imageExtent: extent)
            return
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for mask in masks {
                group.addTask {
                    _ = try BrushMaskRenderer._testRenderCoverage(mask, imageExtent: extent)
                }
            }
            try await group.waitForAll()
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
                    id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", strokeIndex + maskIndex * 10 + 1))!,
                    points: points,
                    size: 0.018,
                    feather: 0.25,
                    flow: 0.6,
                    density: 0.8
                )
            }
            return BrushMask(
                id: UUID(uuidString: String(format: "00000000-0000-4000-9000-%012d", maskIndex + 1))!,
                name: "benchmark-(maskIndex)",
                strokes: strokes,
                adjustments: BrushMaskPatch(exposure: maskIndex.isMultiple(of: 2) ? 0.25 : -0.2)
            )
        }
    }
}
