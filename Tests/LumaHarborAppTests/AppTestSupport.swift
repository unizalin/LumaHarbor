import CoreGraphics
import CoreImage
import Foundation
import XCTest
@testable import EditorCore
@testable import LumaHarborApp
@testable import PhotoLibraryCore
@testable import RawProcessingCore

enum AppTestImage {
    /// A tiny opaque bitmap. These tests care about scheduling and view-model
    /// state, not pixels.
    static func make() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 4,
            height: 4,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return try XCTUnwrap(context.makeImage())
    }
}

/// Records every interactive preview request the view model actually submitted
/// to the scheduler — its exposure value and when the renderer saw it — so a
/// test can prove a rapid drag was throttled instead of queuing one decode per
/// tick.
actor RecordingPreviewRenderer: PreviewRendering {
    struct Call {
        let exposure: Double
        let time: ContinuousClock.Instant
    }

    private(set) var calls: [Call] = []

    func render(_ request: PreviewRequest) async throws -> PreviewImage {
        calls.append(Call(exposure: request.adjustments.exposure, time: .now))
        let image = try AppTestImage.make()
        return PreviewImage(cgImage: image, pixelSize: CGSize(width: 4, height: 4))
    }
}

/// Succeeds for every request except ones whose exposure is in `failingExposures`
/// — lets a test make one specific submission fail without the renderer failing
/// wholesale.
actor SelectivelyFailingPreviewRenderer: PreviewRendering {
    private let failingExposures: Set<Double>

    init(failingExposures: Set<Double>) {
        self.failingExposures = failingExposures
    }

    func render(_ request: PreviewRequest) async throws -> PreviewImage {
        if failingExposures.contains(request.adjustments.exposure) {
            throw RawDecodingError.unsupportedFormat(path: request.url.path)
        }
        let image = try AppTestImage.make()
        return PreviewImage(cgImage: image, pixelSize: CGSize(width: 4, height: 4))
    }
}

/// Lets a test hold one specific exposure's render open until it explicitly
/// releases it, and choose success or failure per exposure -- for proving
/// that a slow, in-flight preview decode can never land *after* a newer
/// preview intent (even a no-op one that submits nothing at all) has already
/// superseded it (round 3, `EditorViewModel.previewIntentVersion`).
actor GatedPreviewRenderer: PreviewRendering {
    private var gates: [Double: AsyncGate] = [:]
    private let shouldFail: @Sendable (Double) -> Bool

    init(shouldFail: @escaping @Sendable (Double) -> Bool = { _ in false }) {
        self.shouldFail = shouldFail
    }

    private func gate(for exposure: Double) -> AsyncGate {
        if let existing = gates[exposure] { return existing }
        let created = AsyncGate()
        gates[exposure] = created
        return created
    }

    /// Lets the render for `exposure` proceed to completion (or failure).
    func release(_ exposure: Double) async {
        await gate(for: exposure).open()
    }

    func render(_ request: PreviewRequest) async throws -> PreviewImage {
        let exposure = request.adjustments.exposure
        await gate(for: exposure).enter()
        if shouldFail(exposure) {
            throw RawDecodingError.unsupportedFormat(path: request.url.path)
        }
        let image = try AppTestImage.make()
        return PreviewImage(cgImage: image, pixelSize: CGSize(width: 4, height: 4))
    }
}

/// A preview renderer that never produces anything.
///
/// The app-level tests are about state transitions, not pixels. A real renderer
/// would fail on the synthetic RAW files here and push an alert onto the view
/// model mid-assertion; this one simply waits until it is cancelled.
struct IdlePreviewRenderer: PreviewRendering {
    func render(_ request: PreviewRequest) async throws -> PreviewImage {
        try await Task.sleep(for: .seconds(3_600))
        throw CancellationError()
    }
}

/// Lets a test decide exactly when an async step finishes.
///
/// Everything here is ordering-sensitive — "did B's selection land before A's
/// read came back" — so nothing is left to a sleep.
actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var enteredCount = 0

    func enter() async {
        enteredCount += 1
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

/// Records what the view model asked the services to do.
actor ServiceCallLog {
    private(set) var savedAdjustments: [(PhotoID, PhotoAdjustments)] = []

    func recordSave(_ photoID: PhotoID, _ adjustments: PhotoAdjustments) {
        savedAdjustments.append((photoID, adjustments))
    }

    var saveCount: Int { savedAdjustments.count }
    var lastSavedAdjustments: PhotoAdjustments? { savedAdjustments.last?.1 }
}

/// Minimal decoder: the app tests never look at an image.
struct StubRawDecoder: RawDecoding {
    let identifier = DecoderIdentifier(kind: "app-test", version: "test")
    func supportsFile(at url: URL) -> Bool { true }
    func readMetadata(at url: URL) throws -> RawMetadata {
        RawMetadata(pixelWidth: 64, pixelHeight: 48)
    }
    func decode(_ request: RawDecodeRequest) throws -> DecodedRawImage {
        throw RawDecodingError.unsupportedFormat(path: request.url.path)
    }
}

/// Lets a test hold `SucceedingRawDecoder.decode` open until released, and
/// count how many decodes actually started -- for proving a batch export's
/// live per-file status (Phase 5 Task 5.1 UI wiring) and its cancellation
/// behaviour, the same way `RawProcessingCoreTests/PhotoExportTests.swift`'s
/// `DecodeGate` does for `BatchExportQueueTests` -- duplicated in miniature
/// here rather than shared, since that type lives in a different test
/// target this one can't import.
final class AppDecodeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isReleased = false
    private var startedCount = 0

    var started: Int {
        lock.lock()
        defer { lock.unlock() }
        return startedCount
    }

    func release() {
        lock.lock()
        isReleased = true
        lock.unlock()
    }

    private var released: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isReleased
    }

    /// Blocks the calling (detached) thread until released or cancelled.
    func enterAndWait(timeout: TimeInterval = 5) {
        lock.lock()
        startedCount += 1
        lock.unlock()

        let deadline = Date().addingTimeInterval(timeout)
        while !released, !Task.isCancelled, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
    }
}

/// A decoder that always succeeds with a tiny flat-colour fixture, optionally
/// gated so a test can control exactly when each decode completes -- used by
/// batch export wiring tests that need at least one item to actually reach
/// `.succeeded` (`StubRawDecoder` above never does).
struct SucceedingRawDecoder: RawDecoding {
    let identifier = DecoderIdentifier(kind: "app-test-succeeding", version: "test")
    var gate: AppDecodeGate?

    func supportsFile(at url: URL) -> Bool { true }
    func readMetadata(at url: URL) throws -> RawMetadata {
        RawMetadata(pixelWidth: 4, pixelHeight: 4)
    }
    func decode(_ request: RawDecodeRequest) throws -> DecodedRawImage {
        gate?.enterAndWait()
        try Task.checkCancellation()
        let size = CGSize(width: 4, height: 4)
        let image = CIImage(color: CIColor(red: 0.4, green: 0.5, blue: 0.6)).cropped(to: CGRect(origin: .zero, size: size))
        return DecodedRawImage(
            image: image,
            nativePixelSize: size,
            decodedPixelSize: size,
            baselineTemperature: 5_500,
            baselineTint: 0,
            metadata: RawMetadata(pixelWidth: 4, pixelHeight: 4)
        )
    }
}

@MainActor
class AppViewModelTestCase: XCTestCase {
    // `setUpWithError` is inherited as nonisolated, and these are only written
    // there and read afterwards, so they sit outside the actor.
    nonisolated(unsafe) private(set) var temporaryDirectory: URL!
    nonisolated(unsafe) private(set) var libraryRoot: URL!
    nonisolated(unsafe) private(set) var supportDirectory: URL!

    nonisolated override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("LumaHarborAppTests-\(UUID().uuidString)", isDirectory: true)
        libraryRoot = temporaryDirectory.appendingPathComponent("Photos", isDirectory: true)
        supportDirectory = temporaryDirectory
            .appendingPathComponent("ApplicationSupport", isDirectory: true)

        for url in [temporaryDirectory, libraryRoot, supportDirectory] {
            try FileManager.default.createDirectory(at: url!, withIntermediateDirectories: true)
        }
    }

    nonisolated override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o755)],
                ofItemAtPath: libraryRoot.path
            )
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    var canSimulateReadOnlyDirectory: Bool { getuid() != 0 }

    @discardableResult
    func seedPhotos(_ names: [String]) throws -> [URL] {
        try names.enumerated().map { index, name in
            var data = Data(repeating: 0x30, count: 256)
            data[0] = UInt8(index)
            let url = libraryRoot.appendingPathComponent(name)
            try data.write(to: url)
            return url
        }
    }

    var locations: ApplicationSupportLocations {
        ApplicationSupportLocations(baseURL: supportDirectory)
    }

    /// Builds the real service graph against the temporary directory, with the
    /// two async steps under the test's control.
    func makeServices(
        loadAdjustments: (@Sendable (PhotoAsset) async throws -> PhotoAdjustments)? = nil,
        saveAdjustments: (@Sendable (PhotoAdjustments, PhotoAsset) async throws -> Void)? = nil,
        previewRenderer: (any PreviewRendering)? = nil,
        decoder: (any RawDecoding)? = nil
    ) throws -> AppServices {
        try locations.createDirectories()
        let decoder = decoder ?? StubRawDecoder()
        let renderService = ImageRenderService()
        let libraryService = try PhotoLibraryService(
            locations: locations,
            decoder: decoder,
            scanner: FolderScanner(batchSize: 1)
        )
        let cache = try DiskCache(
            directoryURL: locations.thumbnailCacheURL,
            byteBudget: 1_000_000
        )
        let renderer = previewRenderer ?? IdlePreviewRenderer()

        return AppServices(
            locations: locations,
            libraryService: libraryService,
            myPresetsRepository: FilePresetRepository(scope: .myPresets(rootURL: locations.presetsDirectoryURL)),
            thumbnailProvider: ThumbnailProvider(
                cache: cache, decoder: decoder, renderService: renderService
            ),
            previewScheduler: PreviewScheduler(renderer: renderer),
            exporter: PhotoExporter(decoder: decoder, renderService: renderService),
            decoder: decoder,
            renderService: renderService,
            previewRenderer: renderer,
            loadAdjustments: loadAdjustments ?? { photo in
                try await libraryService.adjustments(for: photo)
            },
            saveAdjustments: saveAdjustments ?? { adjustments, photo in
                try await libraryService.saveAdjustments(adjustments, for: photo)
            }
        )
    }

    func makeEditorDependencies(from services: AppServices) -> EditorDependencies {
        EditorDependencies(
            previewScheduler: services.previewScheduler,
            previewRenderer: services.previewRenderer,
            loadAdjustments: services.loadAdjustments,
            saveAdjustments: services.saveAdjustments
        )
    }

    /// Registers the temporary folder. Creating a security-scoped bookmark can
    /// fail on a host without the right entitlements, and that is an
    /// environment limitation rather than a product failure — so skip loudly
    /// instead of reporting red.
    func addLibrary(_ services: AppServices) async throws -> LibraryFolder {
        do {
            return try await services.libraryService.addLibrary(
                at: libraryRoot, displayName: "Test Drive"
            )
        } catch let error as LibraryError {
            if case .bookmark = error {
                throw XCTSkip("This host can't create security-scoped bookmarks: \(error)")
            }
            throw error
        }
    }

    func runScan(_ services: AppServices, libraryID: LibraryID) async {
        for await _ in services.libraryService.scan(libraryID: libraryID) {}
    }

    /// Wires a model to the services and loads the given library's photos,
    /// without going through a selection transition.
    func makeModel(
        services: AppServices,
        libraryID: LibraryID
    ) async -> LibraryViewModel {
        let model = LibraryViewModel()
        await model.attachForTesting(services: services)
        await model.selectForTesting(libraryID: libraryID)
        return model
    }

    func waitUntilAppCondition(
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
