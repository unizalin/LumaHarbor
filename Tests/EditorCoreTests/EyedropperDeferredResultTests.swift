import Combine
import CoreGraphics
import Foundation
import XCTest
@testable import EditorCore
import PhotoLibraryCore
import RawProcessingCore

private actor DeferredPreviewRenderer: PreviewRendering {
    struct Request: Sendable { let id: Int; let recipe: PhotoAdjustments }
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<PreviewImage, Error>] = [:]
    private var queued: [Request] = []
    private var arrivals: [CheckedContinuation<Request, Never>] = []

    func render(_ request: PreviewRequest) async throws -> PreviewImage {
        let item = Request(id: nextID, recipe: request.adjustments)
        nextID += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[item.id] = continuation
            if arrivals.isEmpty { queued.append(item) }
            else { arrivals.removeFirst().resume(returning: item) }
        }
    }
    func next() async -> Request {
        if !queued.isEmpty { return queued.removeFirst() }
        return await withCheckedContinuation { arrivals.append($0) }
    }
    func finish(_ request: Request) throws {
        var rgba: [UInt8] = [request.recipe.temperature == 0 ? 100 : 220, 100, 100, 255]
        let context = try XCTUnwrap(CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        pending.removeValue(forKey: request.id)?.resume(returning: PreviewImage(cgImage: image,
            pixelSize: CGSize(width: 1, height: 1), whiteBalanceBaseline: .init(temperatureKelvin: 5500, tint: 0)))
    }
    func cancelAll() {
        for continuation in pending.values { continuation.resume(throwing: CancellationError()) }
        pending.removeAll()
    }
    func fail(_ request: Request) {
        pending.removeValue(forKey: request.id)?.resume(throwing: ImageRenderError.renderFailed)
    }
}

/// Computes from the actual bitmap, but the test controls when those bins
/// reach EditorSession. Cancellation deliberately does not complete the work.
private actor DeferredHistogram {
    struct Request: Sendable { let id: Int; let bins: HistogramData? }
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<HistogramData?, Never>] = [:]
    private var queued: [Request] = []
    private var arrivals: [CheckedContinuation<Request, Never>] = []
    func compute(_ image: CGImage) async -> HistogramData? {
        let item = Request(id: nextID, bins: HistogramComputer.histogram(for: image))
        nextID += 1
        return await withCheckedContinuation { continuation in
            pending[item.id] = continuation
            if arrivals.isEmpty { queued.append(item) }
            else { arrivals.removeFirst().resume(returning: item) }
        }
    }
    func next() async -> Request {
        if !queued.isEmpty { return queued.removeFirst() }
        return await withCheckedContinuation { arrivals.append($0) }
    }
    func finish(_ request: Request) {
        pending.removeValue(forKey: request.id)?.resume(returning: request.bins)
    }
    func cancelAll() {
        for continuation in pending.values { continuation.resume(returning: nil) }
        pending.removeAll()
    }
}

private actor EyedropperSaveSpy {
    var values: [PhotoAdjustments] = []
    func save(_ value: PhotoAdjustments) { values.append(value) }
}

@MainActor
final class EyedropperDeferredResultTests: XCTestCase {
    private let warmSample = WhiteBalanceEyedropper.Sample(red: 0.6, green: 0.5, blue: 0.4)
    private let neutralSample = WhiteBalanceEyedropper.Sample(red: 0.5, green: 0.5, blue: 0.5)

    private func open(_ editor: EditorSession) {
        editor.open(photo: PhotoAsset(id: PhotoID(), libraryID: LibraryID(), relativePath: "fixture.ARW",
            fingerprint: FileFingerprint(fileSize: 4, edgeDigest: "fixture"), status: .ready),
            sourceURL: URL(fileURLWithPath: "/tmp/fixture.ARW"), adjustments: .neutral, isReadOnly: false)
    }

    private func waitForImage(_ editor: EditorSession, red: UInt8) async {
        let ready = expectation(description: "actual red pixel \(red)")
        let subscription = editor.$previewImage.compactMap { $0 }.filter { image in
            guard let data = image.dataProvider?.data else { return false }
            return CFDataGetBytePtr(data)?[0] == red
        }.first().sink { _ in ready.fulfill() }
        await fulfillment(of: [ready], timeout: 2)
        withExtendedLifetime(subscription) {}
    }

    private func bins(red: Int) -> HistogramData {
        var result = HistogramData.empty
        result.red[red] = 1
        result.green[100] = 1
        result.blue[100] = 1
        return result
    }

    private func waitForHistogram(_ editor: EditorSession, red: Int) async {
        let expected = bins(red: red)
        let ready = expectation(description: "all 768 histogram bins")
        let subscription = editor.$histogram.filter { $0 == expected }.first().sink { _ in ready.fulfill() }
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertEqual(editor.histogram, expected)
        withExtendedLifetime(subscription) {}
    }

    private enum Transition: CaseIterable { case neutral, invalid, cancel, externalEdit, photo }
    private func transition(_ action: Transition, editor: EditorSession) {
        switch action {
        case .neutral: editor.previewEyedropper(sample: neutralSample)
        case .invalid: editor.rejectEyedropperSample(.outOfRange)
        case .cancel: editor.cancelEyedropperPreview()
        case .externalEdit: editor.setAdjustment(.exposure, to: 1)
        case .photo: open(editor)
        }
    }

    func testNeutralReleaseAndCancelRestorePixelsAllBinsAndDoNotSave() async throws {
        for release in [true, false] {
            let gate = DeferredPreviewRenderer()
            let hist = DeferredHistogram()
            let saves = EyedropperSaveSpy()
            let editor = EditorSession()
            editor.attach(dependencies: EditorDependencies(previewScheduler: PreviewScheduler(renderer: gate),
                previewRenderer: BaselinePreviewRenderer(), loadAdjustments: { _ in .neutral },
                saveAdjustments: { value, _ in await saves.save(value) },
                computeHistogram: { await hist.compute($0) }))
            open(editor)
            try await gate.finish(await gate.next())
            await waitForImage(editor, red: 100)
            await hist.finish(await hist.next())
            await waitForHistogram(editor, red: 100)
            editor.previewEyedropper(sample: warmSample)
            try await gate.finish(await gate.next())
            await waitForImage(editor, red: 220)
            await hist.finish(await hist.next())
            await waitForHistogram(editor, red: 220)
            editor.previewEyedropper(sample: neutralSample)
            if release { XCTAssertTrue(editor.commitEyedropper()) }
            else { editor.cancelEyedropperPreview() }
            try await gate.finish(await gate.next())
            await waitForImage(editor, red: 100)
            await hist.finish(await hist.next())
            await waitForHistogram(editor, red: 100)
            XCTAssertEqual(editor.displayedAdjustments, .neutral)
            XCTAssertEqual(editor.adjustments, .neutral)
            XCTAssertFalse(editor.canUndo)
            await editor.save()
            let saved = await saves.values
            XCTAssertEqual(saved, [])
            editor.close()
            await gate.cancelAll()
            await hist.cancelAll()
        }
    }

    func testLateSuccessAndErrorAreRejectedAcrossEveryInvalidation() async throws {
        for action in Transition.allCases {
            for fail in [false, true] {
                let gate = DeferredPreviewRenderer()
                let editor = EditorSession()
                editor.attach(dependencies: EditorDependencies(previewScheduler: PreviewScheduler(renderer: gate),
                    previewRenderer: BaselinePreviewRenderer(), loadAdjustments: { _ in .neutral }, saveAdjustments: { _, _ in }))
                open(editor)
                try await gate.finish(await gate.next())
                await waitForImage(editor, red: 100)
                editor.previewEyedropper(sample: warmSample)
                let staleRequest = await gate.next()
                let stale = expectation(description: "stale success/error after \(action)")
                stale.isInverted = true
                var subscriptions: Set<AnyCancellable> = []
                editor.$previewImage.dropFirst().compactMap { $0 }.sink { image in
                    if let data = image.dataProvider?.data, CFDataGetBytePtr(data)?[0] == 220 { stale.fulfill() }
                }.store(in: &subscriptions)
                editor.$previewRenderFailureMessage.compactMap { $0 }.sink { _ in stale.fulfill() }.store(in: &subscriptions)
                editor.$decodeFailed.filter { $0 }.sink { _ in stale.fulfill() }.store(in: &subscriptions)
                transition(action, editor: editor)
                if fail { await gate.fail(staleRequest) }
                else { try await gate.finish(staleRequest) }
                await fulfillment(of: [stale], timeout: 0.15)
                XCTAssertEqual(editor.adjustments.temperature, 0)
                XCTAssertEqual(editor.adjustments.exposure, action == .externalEdit ? 1 : 0)
                XCTAssertNil(editor.previewRenderFailureMessage)
                XCTAssertFalse(editor.decodeFailed)
                editor.close()
                await gate.cancelAll()
                withExtendedLifetime(subscriptions) {}
            }
        }
    }

    func testLateHistogramCannotPublishAcrossEveryInvalidation() async throws {
        for action in Transition.allCases {
            let gate = DeferredPreviewRenderer()
            let hist = DeferredHistogram()
            let editor = EditorSession()
            editor.attach(dependencies: EditorDependencies(previewScheduler: PreviewScheduler(renderer: gate),
                previewRenderer: BaselinePreviewRenderer(), loadAdjustments: { _ in .neutral },
                saveAdjustments: { _, _ in }, computeHistogram: { await hist.compute($0) }))
            open(editor)
            try await gate.finish(await gate.next())
            await waitForImage(editor, red: 100)
            await hist.finish(await hist.next())
            await waitForHistogram(editor, red: 100)
            editor.previewEyedropper(sample: warmSample)
            try await gate.finish(await gate.next())
            await waitForImage(editor, red: 220)
            let oldHistogram = await hist.next()
            XCTAssertEqual(oldHistogram.bins, bins(red: 220))
            transition(action, editor: editor)
            let stale = expectation(description: "stale histogram after \(action)")
            stale.isInverted = true
            let subscription = editor.$histogram.filter { $0 == self.bins(red: 220) }.sink { _ in stale.fulfill() }
            await hist.finish(oldHistogram)
            await fulfillment(of: [stale], timeout: 0.15)
            try await gate.finish(await gate.next())
            await waitForImage(editor, red: 100)
            await hist.finish(await hist.next())
            await waitForHistogram(editor, red: 100)
            editor.close()
            await gate.cancelAll()
            await hist.cancelAll()
            withExtendedLifetime(subscription) {}
        }
    }

    func testAnOldCandidateFrameCannotPublishAfterAnExternalEdit() async throws {
        let gate = DeferredPreviewRenderer()
        let editor = EditorSession()
        editor.attach(dependencies: EditorDependencies(previewScheduler: PreviewScheduler(renderer: gate),
            previewRenderer: BaselinePreviewRenderer(), loadAdjustments: { _ in .neutral }, saveAdjustments: { _, _ in }))
        let photo = PhotoAsset(id: PhotoID(), libraryID: LibraryID(), relativePath: "fixture.ARW",
            fingerprint: FileFingerprint(fileSize: 4, edgeDigest: "fixture"), status: .ready)
        let first = expectation(description: "initial frame")
        var subscriptions: Set<AnyCancellable> = []
        editor.$previewImage.compactMap { $0 }.first().sink { _ in first.fulfill() }.store(in: &subscriptions)
        editor.open(photo: photo, sourceURL: URL(fileURLWithPath: "/tmp/fixture.ARW"), adjustments: .neutral, isReadOnly: false)
        try await gate.finish(await gate.next())
        await fulfillment(of: [first], timeout: 2)

        editor.previewEyedropper(sample: .init(red: 0.6, green: 0.5, blue: 0.4))
        let warm = await gate.next()
        XCTAssertNotEqual(warm.recipe.temperature, 0)
        let stale = expectation(description: "old candidate must not publish")
        stale.isInverted = true
        editor.$previewImage.dropFirst().compactMap { $0 }.sink { image in
            if let data = image.dataProvider?.data, CFDataGetBytePtr(data)?[0] == 220 { stale.fulfill() }
        }.store(in: &subscriptions)
        editor.setAdjustment(.exposure, to: 1)
        // Complete the old render explicitly while every replacement is held.
        try await gate.finish(warm)
        await fulfillment(of: [stale], timeout: 0.2)
        XCTAssertEqual(editor.adjustments.exposure, 1)
        XCTAssertEqual(editor.displayedAdjustments.exposure, 1)
        editor.close()
        await gate.cancelAll()
        withExtendedLifetime(subscriptions) {}
    }
}
