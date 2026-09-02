import CoreGraphics
import Foundation
import XCTest
@testable import EditorCore
import PhotoLibraryCore
import RawProcessingCore

/// Lets a test control exactly when each *histogram computation* (not each
/// preview render) resolves, keyed purely by call order: the 1st call to
/// `computeHistogram` is index 0, the 2nd is index 1, and so on. This makes
/// it possible to prove a slow histogram computation for an
/// already-superseded preview frame can never overwrite a newer one that
/// already landed, independent of preview-render staleness itself (already
/// covered by `EditorSessionAlertPrivacyTests`'s neighbors).
private actor HistogramCallGate {
    private var waiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var released: Set<Int> = []
    private var callCount = 0
    private(set) var arrivedCount = 0

    /// Called from inside the injected `computeHistogram` closure. Returns
    /// once this call's index has been released.
    func enter() async {
        let index = callCount
        callCount += 1
        arrivedCount += 1
        guard !released.contains(index) else { return }
        await withCheckedContinuation { continuation in
            waiters[index, default: []].append(continuation)
        }
    }

    func release(_ index: Int) {
        released.insert(index)
        let pending = waiters.removeValue(forKey: index) ?? []
        for continuation in pending { continuation.resume() }
    }
}

/// Produces a distinct flat-gray image per exposure value, fast and never
/// gated -- only the histogram *computation* itself is gated in this file's
/// staleness test, isolating it from preview-render staleness.
private struct DistinctColorPerExposureRenderer: PreviewRendering {
    func render(_ request: PreviewRequest) async throws -> PreviewImage {
        let intensity = UInt8(clamping: Int(128 + request.adjustments.exposure * 40))
        let image = try Self.makeImage(intensity: intensity)
        return PreviewImage(cgImage: image, pixelSize: CGSize(width: 4, height: 4))
    }

    private static func makeImage(intensity: UInt8) throws -> CGImage {
        var pixelData = [UInt8](repeating: 0, count: 4 * 4 * 4)
        for pixel in 0..<16 {
            let offset = pixel * 4
            pixelData[offset] = intensity
            pixelData[offset + 1] = intensity
            pixelData[offset + 2] = intensity
            pixelData[offset + 3] = 255
        }
        let context = try XCTUnwrap(CGContext(
            data: &pixelData,
            width: 4,
            height: 4,
            bitsPerComponent: 8,
            bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try XCTUnwrap(context.makeImage())
    }
}

@MainActor
final class EditorSessionHistogramTests: XCTestCase {
    private func makePhoto() -> PhotoAsset {
        PhotoAsset(
            id: PhotoID(),
            libraryID: LibraryID(),
            relativePath: "fixture.ARW",
            fingerprint: FileFingerprint(fileSize: 4, edgeDigest: "fixture"),
            status: .ready
        )
    }

    private func waitUntilCondition(
        timeout: TimeInterval = 3,
        _ condition: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for condition")
    }

    /// AwayPhotoRawEditor parity Phase 1 Task 2: histogram refresh must be
    /// versioned the same way `previewImage` already is -- a slower
    /// computation for a frame the user has since moved on from must never
    /// overwrite the histogram for whatever frame is actually displayed now.
    func testAStaleHistogramComputationNeverOverwritesTheHistogramForTheCurrentlyDisplayedFrame() async throws {
        let gate = HistogramCallGate()
        let renderer = DistinctColorPerExposureRenderer()
        let editor = EditorSession()
        editor.attach(dependencies: EditorDependencies(
            previewScheduler: PreviewScheduler(renderer: renderer),
            previewRenderer: renderer,
            loadAdjustments: { _ in .neutral },
            saveAdjustments: { _, _ in },
            computeHistogram: { image in
                await gate.enter()
                return HistogramComputer.histogram(for: image)
            }
        ))

        editor.open(
            photo: makePhoto(),
            sourceURL: URL(fileURLWithPath: "/tmp/fixture.ARW"),
            adjustments: .neutral,
            isReadOnly: false
        )
        try await waitUntilCondition { await gate.arrivedCount >= 1 }

        editor.setAdjustment(.exposure, to: 4.0)
        try await waitUntilCondition { await gate.arrivedCount >= 2 }

        // Release the *second* (newer) computation first -- it lands and
        // becomes the displayed histogram.
        await gate.release(1)
        try await waitUntilCondition { editor.histogram != nil }
        let histogramAfterSecondFrame = editor.histogram

        // Now release the *first* (stale) computation, which has been
        // blocked this whole time. It must not overwrite what's displayed.
        await gate.release(0)
        // No further observable state changes when the stale release is
        // correctly ignored -- give it a beat to actually resume and reach
        // its own generation guard before asserting nothing changed.
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(
            editor.histogram, histogramAfterSecondFrame,
            "a stale histogram computation for an already-superseded frame must never overwrite the current one"
        )
    }

    /// Baseline the staleness test above depends on: a normal, ungated
    /// histogram computation actually reaches `editor.histogram`, using the
    /// real default `computeHistogram` (not a test override).
    func testHistogramPopulatesAfterAPreviewRenders() async throws {
        let renderer = DistinctColorPerExposureRenderer()
        let editor = EditorSession()
        editor.attach(dependencies: EditorDependencies(
            previewScheduler: PreviewScheduler(renderer: renderer),
            previewRenderer: renderer,
            loadAdjustments: { _ in .neutral },
            saveAdjustments: { _, _ in }
        ))

        XCTAssertNil(editor.histogram, "no histogram before anything has ever rendered")

        editor.open(
            photo: makePhoto(),
            sourceURL: URL(fileURLWithPath: "/tmp/fixture.ARW"),
            adjustments: .neutral,
            isReadOnly: false
        )

        try await waitUntilCondition { editor.histogram != nil }
        XCTAssertNotNil(editor.histogram)
    }

    /// Acceptance: "empty/failed preview states show clear localized
    /// fallback copy" -- at the model level, that means `histogram` must go
    /// back to `nil` (never a stale, misleading histogram) once the photo
    /// closes.
    func testHistogramClearsWhenThePhotoCloses() async throws {
        let renderer = DistinctColorPerExposureRenderer()
        let editor = EditorSession()
        editor.attach(dependencies: EditorDependencies(
            previewScheduler: PreviewScheduler(renderer: renderer),
            previewRenderer: renderer,
            loadAdjustments: { _ in .neutral },
            saveAdjustments: { _, _ in }
        ))
        editor.open(
            photo: makePhoto(),
            sourceURL: URL(fileURLWithPath: "/tmp/fixture.ARW"),
            adjustments: .neutral,
            isReadOnly: false
        )
        try await waitUntilCondition { editor.histogram != nil }

        editor.close()

        XCTAssertNil(editor.histogram, "closing the photo must clear any previously computed histogram")
    }
}
