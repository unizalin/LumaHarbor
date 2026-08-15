import CoreGraphics
import Foundation
import XCTest
@testable import RawProcessingCore

enum TestImage {
    /// A tiny opaque bitmap. The preview tests care about scheduling, not
    /// pixels, so this avoids dragging Core Image into them.
    static func make(width: Int = 4, height: Int = 4) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
}

extension XCTestCase {
    /// Polls until `condition` holds.
    ///
    /// The preview scheduler's guarantees are about ordering, not latency, so
    /// tests wait for a state rather than sleeping for a guessed duration.
    func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @Sendable () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for \(description)", file: file, line: line)
    }
}

/// A renderer the test releases by hand, so cancellation and staleness are
/// exercised without depending on how long a real decode takes.
struct ManualPreviewRenderer: PreviewRendering {
    /// Coordinates which in-flight renders are allowed to finish.
    actor Gate {
        private var waiters: [String: CheckedContinuation<Void, Never>] = [:]
        private var released: Set<String> = []
        /// Set once `releaseAll()` has ever been called. `submit()` hands the
        /// render work to an unstructured `Task`, so a slower one can still
        /// reach `wait(for:)` *after* the test already called `releaseAll()` —
        /// without this flag that continuation would never be registered in
        /// time to be resumed, and would hang forever.
        private var allReleased = false
        private var startedKeys: [String] = []

        func wait(for key: String) async {
            startedKeys.append(key)
            guard !released.contains(key), !allReleased else { return }
            await withCheckedContinuation { continuation in
                waiters[key] = continuation
            }
        }

        func release(_ key: String) {
            released.insert(key)
            waiters.removeValue(forKey: key)?.resume()
        }

        func releaseAll() {
            allReleased = true
            for (key, continuation) in waiters {
                released.insert(key)
                continuation.resume()
            }
            waiters.removeAll()
        }

        var started: [String] { startedKeys }
    }

    let gate: Gate
    /// `false` models a renderer that finishes anyway, which is what proves the
    /// scheduler drops stale results at delivery time rather than relying on
    /// cooperative cancellation.
    var respectsCancellation: Bool = true

    /// Requests are identified by their exposure value, which reads clearly in
    /// the tests.
    static func key(for request: PreviewRequest) -> String {
        String(format: "%.1f", request.adjustments.exposure)
    }

    func render(_ request: PreviewRequest) async throws -> PreviewImage {
        await gate.wait(for: Self.key(for: request))
        if respectsCancellation {
            try Task.checkCancellation()
        }
        let image = try TestImage.make()
        return PreviewImage(cgImage: image, pixelSize: CGSize(width: 4, height: 4))
    }
}

/// A renderer that always fails, for the error-path test.
struct FailingPreviewRenderer: PreviewRendering {
    let error: RawDecodingError

    func render(_ request: PreviewRequest) async throws -> PreviewImage {
        throw error
    }
}

extension PreviewRequest {
    /// Exposure doubles as the request's identity in these tests.
    static func stub(
        subject: PreviewSubject,
        exposure: Double,
        quality: PreviewQuality = .interactive
    ) -> PreviewRequest {
        PreviewRequest(
            subject: subject,
            url: URL(fileURLWithPath: "/tmp/lumaharbor-test.ARW"),
            adjustments: PhotoAdjustments(exposure: exposure),
            targetPixelDimension: 512,
            quality: quality
        )
    }
}
