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
    /// 0...1, where 1 is least compressed.
    public var jpegQuality: Double

    public init(
        sourceURL: URL,
        adjustments: PhotoAdjustments,
        destinationDirectory: URL,
        baseFilename: String,
        jpegQuality: Double = 0.9
    ) {
        self.sourceURL = sourceURL
        self.adjustments = adjustments
        self.destinationDirectory = destinationDirectory
        self.baseFilename = baseFilename
        self.jpegQuality = jpegQuality
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
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .destinationNotWritable, .destinationUnavailable, .couldNotFindUniqueName:
            return L10n.t("Choose a different output location.")
        case .insufficientDiskSpace:
            return L10n.t("Free up space or choose a different destination, then export again.")
        case .cancelled:
            return nil
        case .decoding(let error):
            return error.recoverySuggestion
        case .rendering(let error):
            return error.recoverySuggestion
        }
    }
}

/// Full-resolution JPEG export.
///
/// Spec §6.3: the export always re-decodes the original RAW — never the preview
/// cache — is cancellable, and leaves no partial output behind when it stops.
public actor JPEGExporter {
    private let decoder: any RawDecoding
    private let pipeline: AdjustmentPipeline
    private let renderService: ImageRenderService
    private let fileManager: FileManager

    public init(
        decoder: any RawDecoding = CoreImageRawDecoder(),
        pipeline: AdjustmentPipeline = AdjustmentPipeline(),
        renderService: ImageRenderService = ImageRenderService(),
        fileManager: FileManager = .default
    ) {
        self.decoder = decoder
        self.pipeline = pipeline
        self.renderService = renderService
        self.fileManager = fileManager
    }

    public func export(_ request: ExportRequest) async throws -> ExportOutcome {
        let directory = request.destinationDirectory

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ExportError.destinationUnavailable(path: directory.path)
        }
        guard fileManager.isWritableFile(atPath: directory.path) else {
            throw ExportError.destinationNotWritable(path: directory.path)
        }

        guard let finalURL = UniqueFilenameResolver.resolve(
            baseName: request.baseFilename,
            fileExtension: "jpg",
            in: directory,
            fileManager: fileManager
        ) else {
            throw ExportError.couldNotFindUniqueName(baseName: request.baseFilename)
        }

        // Write to a hidden sibling first: same volume, so the final move is a
        // rename, and a cancelled export never leaves a half-written .jpg that
        // looks finished.
        let temporaryURL = directory.appendingPathComponent(
            ".lumaharbor-export-\(UUID().uuidString).tmp"
        )

        do {
            try await renderToDisk(request, temporaryURL: temporaryURL)
            try checkCancellation(cleaningUp: temporaryURL)

            let attributes = try? fileManager.attributesOfItem(atPath: temporaryURL.path)
            let byteCount = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            let pixelSize = try await fullResolutionPixelSize(of: request.sourceURL)

            // Re-check right before the rename. Cancellation can land during the
            // metadata read above, and a decoder that doesn't poll for it will
            // return a value anyway — at which point the move would publish a
            // finished-looking .jpg for an export the user already stopped.
            // The rename is the only irreversible step, so it is the one that
            // must lose the race.
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
        let quality = request.jpegQuality

        // Spec §11: no decoding or encoding on the main thread. Spec §6.3: the
        // export stays cancellable while it runs.
        try await runOffActor(priority: .userInitiated) {
            try Task.checkCancellation()
            let decoded = try decoder.decode(decodeRequest)

            try Task.checkCancellation()
            let adjusted = pipeline.apply(parameters, to: decoded.image, scaleFactor: decoded.scaleFactor)

            try Task.checkCancellation()
            try renderService.writeJPEG(adjusted, to: temporaryURL, quality: quality)
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
