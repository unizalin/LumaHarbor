import CoreImage
import Foundation
import XCTest
@testable import RawProcessingCore

final class BrushMaskCancellationTests: XCTestCase {
    func testCancellationCheckCanStopAfterCoverageRasterizationBegins() throws {
        let source = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: 400, height: 300))
        let mask = BrushMask(
            strokes: [BrushMaskStroke(
                points: [BrushMaskPoint(x: 0.5, y: 0.5)],
                size: 0.2,
                feather: 0.25,
                flow: 0.8
            )],
            adjustments: BrushMaskPatch(exposure: 1)
        )
        let probe = CancellationProbe(throwAt: 9)

        XCTAssertThrowsError(try BrushMaskRenderer.applyValidated(
            [mask],
            to: source,
            cancellationCheck: { try probe.check() }
        )) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertGreaterThanOrEqual(probe.count, 9)
    }

    func testAsyncCancellationStopsAParallelCoverageWorker() async throws {
        let source = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: 400, height: 300))
        let mask = BrushMask(
            strokes: [BrushMaskStroke(
                points: [BrushMaskPoint(x: 0.5, y: 0.5)],
                size: 0.2,
                feather: 0.25,
                flow: 0.8
            )],
            adjustments: BrushMaskPatch(exposure: 1)
        )
        let probe = CancellationProbe(throwAt: 9)

        do {
            _ = try await BrushMaskRenderer.applyValidatedAsync(
                [mask],
                to: source,
                cancellationCheck: { try probe.check() }
            )
            XCTFail("coverage cancellation must propagate")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertGreaterThanOrEqual(probe.count, 9)
    }

    private final class CancellationProbe: @unchecked Sendable {
        private let lock = NSLock()
        private let throwAt: Int
        private(set) var count = 0

        init(throwAt: Int) {
            self.throwAt = throwAt
        }

        func check() throws {
            lock.lock()
            count += 1
            let current = count
            lock.unlock()
            if current >= throwAt { throw CancellationError() }
        }
    }
}
