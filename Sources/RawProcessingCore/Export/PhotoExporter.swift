import CoreGraphics
import Localization
import CoreImage
import Foundation

public struct ExportRequest: Sendable {
    public var sourceURL: URL
    public var adjustments: PhotoAdjustments
    public var destinationDirectory: URL
    /// Filename without extension; collisions get a serial suffix.
    public var baseFilename: String
    public var format: ExportFormat
    /// 0...1, where 1 is least compressed. Ignored unless `format.usesQuality`.
    public var quality: Double
    /// Ignored unless `format.supportsBitDepthChoice` (TIFF only, for now).
    public var bitDepth: ExportBitDepth
    /// Longest-edge caps in pixels. `nil` means "no limit on that axis";
    /// aspect ratio is always preserved and the image is never upscaled.
    public var maximumWidth: Int?
    public var maximumHeight: Int?
    /// Pixels-per-inch written into the output's resolution metadata.
    /// `nil` leaves the encoder's own default.
    public var dpi: Double?
    public var exifRetentionPolicy: ExifRetentionPolicy
    /// What to do when `baseFilename.<extension>` already exists at
    /// `destinationDirectory` (design spec §6.11; roadmap Phase 5 Task 5.2).
    /// Defaults to `.increment`, the behaviour every export had before this
    /// field existed, so no existing call site's behaviour changes.
    public var collisionPolicy: ExportCollisionPolicy
    /// `nil` (the default) adds no watermark, byte-for-byte identical to
    /// every export before this field existed (design spec §6.11; roadmap
    /// Phase 5 Task 5.2).
    public var watermark: Watermark?

    public init(
        sourceURL: URL,
        adjustments: PhotoAdjustments,
        destinationDirectory: URL,
        baseFilename: String,
        format: ExportFormat = .jpeg,
        quality: Double = 0.9,
        bitDepth: ExportBitDepth = .eightBit,
        maximumWidth: Int? = nil,
        maximumHeight: Int? = nil,
        dpi: Double? = nil,
        exifRetentionPolicy: ExifRetentionPolicy = .preserveAll,
        collisionPolicy: ExportCollisionPolicy = .increment,
        watermark: Watermark? = nil
    ) {
        self.sourceURL = sourceURL
        self.adjustments = adjustments
        self.destinationDirectory = destinationDirectory
        self.baseFilename = baseFilename
        self.format = format
        self.quality = quality
        self.bitDepth = bitDepth
        self.maximumWidth = maximumWidth
        self.maximumHeight = maximumHeight
        self.dpi = dpi
        self.exifRetentionPolicy = exifRetentionPolicy
        self.watermark = watermark
        self.collisionPolicy = collisionPolicy
    }
}

public struct ExportOutcome: Sendable, Equatable {
    public let url: URL
    public let pixelSize: CGSize
    public let byteCount: Int64

    public init(url: URL, pixelSize: CGSize, byteCount: Int64) {
        self.url = url
        self.pixelSize = pixelSize
        self.byteCount = byteCount
    }
}

public enum ExportError: Error, Equatable, Sendable {
    case destinationNotWritable(path: String)
    case destinationUnavailable(path: String)
    case couldNotFindUniqueName(baseName: String)
    case insufficientDiskSpace
    case cancelled
    case decoding(RawDecodingError)
    case rendering(ImageRenderError)
    /// The requested format has no encoder on this build/platform (plan:
    /// "if a platform cannot encode one format, show disabled/unsupported UI
    /// instead of pretending success"). Caught before anything is written.
    case formatNotSupported(ExportFormat)
    /// `.skip` collision policy and a file already sits at the exact
    /// destination name -- not an error the user needs to fix, but still not
    /// a success, so it must not be silently absorbed into either. Caught
    /// before the decoder ever runs (design spec §8.3: never disguise a
    /// skip as success, and never do the expensive work just to throw it
    /// away).
    case skippedExistingFile
    /// `.ask` collision policy was selected. There is no interactive prompt
    /// implemented for a sequential batch export to pause on, so this fails
    /// loudly rather than silently behaving like `.increment` or `.skip`.
    case collisionPolicyNotSupported
}

extension ExportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .destinationNotWritable:
            return L10n.t("That export location is read-only.")
        case .destinationUnavailable:
            return L10n.t("The export location isn't available.")
        case .couldNotFindUniqueName(let baseName):
            return "\(L10n.t("Couldn't find an unused filename for")) \"\(baseName)\"."
        case .insufficientDiskSpace:
            return L10n.t("There isn't enough free space to finish the export.")
        case .cancelled:
            return L10n.t("The export was cancelled.")
        case .decoding(let error):
            return error.errorDescription
        case .rendering(let error):
            return error.errorDescription
        case .formatNotSupported(let format):
            return "\(L10n.t("This Mac can't export")) \(format.displayName)."
        case .skippedExistingFile:
            return L10n.t("A file with this name already exists, so this export was skipped.")
        case .collisionPolicyNotSupported:
            return L10n.t("Asking before each export isn't supported yet.")
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .destinationNotWritable, .destinationUnavailable, .couldNotFindUniqueName:
            return L10n.t("Choose a different output location.")
        case .insufficientDiskSpace:
            return L10n.t("Free up space or choose a different destination, then export again.")
        case .cancelled, .skippedExistingFile:
            return nil
        case .collisionPolicyNotSupported:
            return L10n.t("Choose Increment or Skip instead.")
        case .decoding(let error):
            return error.recoverySuggestion
        case .rendering(let error):
            return error.recoverySuggestion
        case .formatNotSupported:
            return L10n.t("Choose a different export format.")
        }
    }
}

/// Full-resolution single-photo export (design spec §6.11).
///
/// Spec §6.3: the export always re-decodes the original RAW — never the preview
/// cache — is cancellable, and leaves no partial output behind when it stops.
public actor PhotoExporter {
    private let decoder: any RawDecoding
    private let pipeline: AdjustmentPipeline
    private let renderService: ImageRenderService
    private let fileManager: FileManager
    /// Injectable so a platform build without an encoder for some format
    /// (no HEIC codec, say) can be simulated in tests instead of only ever
    /// matching whatever the machine running the suite happens to support.
    private let encodableTypeIdentifiers: @Sendable () -> Set<String>

    public init(
        decoder: any RawDecoding = CoreImageRawDecoder(),
        pipeline: AdjustmentPipeline = AdjustmentPipeline(),
        renderService: ImageRenderService = ImageRenderService(),
        fileManager: FileManager = .default,
        encodableTypeIdentifiers: @escaping @Sendable () -> Set<String> = ExportFormat.systemEncodableTypeIdentifiers
    ) {
        self.decoder = decoder
        self.pipeline = pipeline
        self.renderService = renderService
        self.fileManager = fileManager
        self.encodableTypeIdentifiers = encodableTypeIdentifiers
    }

    public func export(_ request: ExportRequest) async throws -> ExportOutcome {
        guard request.format.isSupported(by: encodableTypeIdentifiers()) else {
            throw ExportError.formatNotSupported(request.format)
        }

        let directory = request.destinationDirectory

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ExportError.destinationUnavailable(path: directory.path)
        }
        guard fileManager.isWritableFile(atPath: directory.path) else {
            throw ExportError.destinationNotWritable(path: directory.path)
        }

        let finalURL: URL
        switch UniqueFilenameResolver.resolve(
            baseName: request.baseFilename,
            fileExtension: request.format.fileExtension,
            in: directory,
            policy: request.collisionPolicy,
            fileManager: fileManager
        ) {
        case .proceed(let url):
            finalURL = url
        case .skip:
            // Caught before the temp file is even created, let alone the
            // decoder invoked -- a skip must never pay for a decode/render
            // it then throws away.
            throw ExportError.skippedExistingFile
        case .incrementExhausted:
            throw ExportError.couldNotFindUniqueName(baseName: request.baseFilename)
        case .unsupportedAsk:
            throw ExportError.collisionPolicyNotSupported
        }

        // Write to a hidden sibling first: same volume, so the final move is a
        // rename, and a cancelled export never leaves a half-written output
        // file that looks finished.
        let temporaryURL = directory.appendingPathComponent(
            ".lumaharbor-export-\(UUID().uuidString).tmp"
        )

        do {
            try await renderToDisk(request, temporaryURL: temporaryURL)
            try checkCancellation(cleaningUp: temporaryURL)

            let attributes = try? fileManager.attributesOfItem(atPath: temporaryURL.path)
            let byteCount = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            let nativePixelSize = try await fullResolutionPixelSize(of: request.sourceURL)
            let geometryAdjustedSize = GeometryRenderer.appliedPixelSize(
                of: nativePixelSize,
                geometry: request.adjustments.geometry
            )
            let pixelSize = ExportResizing.fittedSize(
                nativeSize: geometryAdjustedSize,
                maximumWidth: request.maximumWidth,
                maximumHeight: request.maximumHeight
            )

            // Re-check right before the rename. Cancellation can land during the
            // metadata read above, and a decoder that doesn't poll for it will
            // return a value anyway — at which point the move would publish a
            // finished-looking output file for an export the user already
            // stopped. The rename is the only irreversible step, so it is the
            // one that must lose the race.
            try checkCancellation(cleaningUp: temporaryURL)

            try fileManager.moveItem(at: temporaryURL, to: finalURL)
            return ExportOutcome(url: finalURL, pixelSize: pixelSize, byteCount: byteCount)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw Self.mapError(error)
        }
    }

    // MARK: - Private

    private func renderToDisk(_ request: ExportRequest, temporaryURL: URL) async throws {
        let parameters = AdjustmentMapping.renderParameters(for: request.adjustments)
        let decodeRequest = RawDecodeRequest(
            url: request.sourceURL,
            quality: .full,
            whiteBalance: parameters.whiteBalance
        )
        let decoder = self.decoder
        let pipeline = self.pipeline
        let renderService = self.renderService
        let format = request.format
        let quality = request.quality
        let bitDepth = request.bitDepth
        let dpi = request.dpi
        let exifPolicy = request.exifRetentionPolicy
        let maximumWidth = request.maximumWidth
        let maximumHeight = request.maximumHeight
        let watermark = request.watermark

        // Spec §11: no decoding or encoding on the main thread. Spec §6.3: the
        // export stays cancellable while it runs.
        try await runOffActor(priority: .userInitiated) {
            try Task.checkCancellation()
            // `.full` -- always the native-resolution decode, never the
            // screen-sized preview (plan: "ensure export renders from
            // full-resolution source, not preview cache").
            let decoded = try decoder.decode(decodeRequest)

            try Task.checkCancellation()
            let adjusted = pipeline.apply(parameters, to: decoded.image, scaleFactor: decoded.scaleFactor)
            let withGeometry = GeometryRenderer.apply(request.adjustments.geometry, to: adjusted)
            // Local adjustments (Phase 4 Task 4.2) run after geometry, same
            // as the preview path (`CoreImagePreviewRenderer`) and for the
            // same reason: a gradient's anchor point is placed on the
            // already-rotated/cropped displayed preview, so it must be
            // interpreted in that same coordinate space here too -- this is
            // what makes "export renders from full-resolution source and
            // applies local edits" true rather than the export silently
            // reverting to a geometry-only render.
            let withLocalAdjustments = LocalAdjustmentRenderer.apply(request.adjustments.localAdjustments, to: withGeometry)
            let resizeTransform = ExportResizing.fittingTransform(
                // The *geometry-adjusted* extent, not `decoded.nativePixelSize`:
                // a crop/rotate changes what "native size" means for the
                // max-width/max-height fit, and this is the real rendered
                // extent, not a prediction (`GeometryRenderer
                // .appliedPixelSize(of:geometry:)` is only for the
                // metadata-only size report below, which has no decoded
                // image to read an extent from). Local adjustments never
                // change the extent, so reusing it here is exact, not a
                // second prediction.
                nativeSize: withLocalAdjustments.extent.size,
                maximumWidth: maximumWidth,
                maximumHeight: maximumHeight
            )
            let resized = resizeTransform == .identity ? withLocalAdjustments : withLocalAdjustments.transformed(by: resizeTransform)
            // Watermarked last, against the final output pixel size --
            // `sizeFraction`/position are meant to read consistently on the
            // actual exported dimensions, not the pre-resize native ones.
            let watermarked = WatermarkRenderer.apply(watermark, to: resized)

            try Task.checkCancellation()
            let exifProperties = ExportMetadataBuilder.imageProperties(from: exifPolicy.apply(to: decoded.metadata))
            try renderService.writeExport(
                watermarked,
                to: temporaryURL,
                format: format,
                quality: quality,
                bitDepth: bitDepth,
                dpi: dpi,
                exifProperties: exifProperties
            )
        }
    }

    private func fullResolutionPixelSize(of url: URL) async throws -> CGSize {
        let decoder = self.decoder
        let metadata = try await runOffActor(priority: .utility) {
            try decoder.readMetadata(at: url)
        }
        return CGSize(width: metadata.pixelWidth, height: metadata.pixelHeight)
    }

    private func checkCancellation(cleaningUp url: URL) throws {
        if Task.isCancelled {
            try? fileManager.removeItem(at: url)
            throw ExportError.cancelled
        }
    }

    static func mapError(_ error: Error) -> Error {
        switch error {
        case let error as ExportError:
            return error
        case let error as RawDecodingError:
            return ExportError.decoding(error)
        case let error as ImageRenderError:
            return ExportError.rendering(error)
        case is CancellationError:
            return ExportError.cancelled
        default:
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteOutOfSpaceError {
                return ExportError.insufficientDiskSpace
            }
            if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOSPC) {
                return ExportError.insufficientDiskSpace
            }
            return error
        }
    }
}
