import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Metal

public enum ImageRenderError: Error, Equatable, Sendable {
    case renderFailed
    case encodingFailed
    case insufficientDiskSpace
    case destinationNotWritable(path: String)
}

extension ImageRenderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .renderFailed:
            return String(localized: "The image couldn't be rendered.")
        case .encodingFailed:
            return String(localized: "The JPEG couldn't be encoded.")
        case .insufficientDiskSpace:
            return String(localized: "There isn't enough free space to finish writing the file.")
        case .destinationNotWritable:
            return String(localized: "That location can't be written to.")
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .insufficientDiskSpace:
            return String(localized: "Free up space or choose a different destination, then export again.")
        case .destinationNotWritable:
            return String(localized: "Choose a different output location.")
        case .renderFailed, .encodingFailed:
            return String(localized: "Try exporting again.")
        }
    }
}

/// Owns the `CIContext` and every colour-space decision.
///
/// Spec §9: the working gamut and output profile are managed centrally, and
/// MVP display + JPEG output must at minimum be tagged sRGB.
public final class ImageRenderService: @unchecked Sendable {
    /// Extended-range linear space, so highlights above 1.0 survive the chain
    /// until the final output transform clips them.
    public static let workingColorSpace: CGColorSpace =
        CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
            ?? CGColorSpaceCreateDeviceRGB()

    public static let outputColorSpace: CGColorSpace =
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    private let context: CIContext

    /// Uses the default Metal device when one exists. Falling back to the CPU
    /// context keeps unit tests runnable on machines without a usable GPU
    /// (headless CI, for instance) instead of crashing at init.
    public init(preferMetal: Bool = true) {
        let options: [CIContextOption: Any] = [
            .workingColorSpace: Self.workingColorSpace,
            .outputColorSpace: Self.outputColorSpace,
            .cacheIntermediates: false
        ]
        if preferMetal, let device = MTLCreateSystemDefaultDevice() {
            self.context = CIContext(mtlDevice: device, options: options)
        } else {
            self.context = CIContext(options: options)
        }
    }

    public func makeCGImage(_ image: CIImage) throws -> CGImage {
        let extent = image.extent
        guard !extent.isInfinite, !extent.isEmpty else {
            throw ImageRenderError.renderFailed
        }
        guard let cgImage = context.createCGImage(
            image,
            from: extent,
            format: .RGBA8,
            colorSpace: Self.outputColorSpace
        ) else {
            throw ImageRenderError.renderFailed
        }
        return cgImage
    }

    public func jpegData(from image: CIImage, quality: Double) throws -> Data {
        guard !image.extent.isInfinite, !image.extent.isEmpty else {
            throw ImageRenderError.renderFailed
        }
        let options: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String):
                Self.clampQuality(quality)
        ]
        guard let data = context.jpegRepresentation(
            of: image,
            colorSpace: Self.outputColorSpace,
            options: options
        ) else {
            throw ImageRenderError.encodingFailed
        }
        return data
    }

    /// Writes straight to disk so a full-resolution export never has to hold the
    /// encoded JPEG in memory alongside the rendered bitmap.
    public func writeJPEG(_ image: CIImage, to url: URL, quality: Double) throws {
        guard !image.extent.isInfinite, !image.extent.isEmpty else {
            throw ImageRenderError.renderFailed
        }
        let options: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String):
                Self.clampQuality(quality)
        ]
        do {
            try context.writeJPEGRepresentation(
                of: image,
                to: url,
                colorSpace: Self.outputColorSpace,
                options: options
            )
        } catch {
            throw Self.mapWriteError(error, url: url)
        }
    }

    /// Releases GPU-side caches. Called when the app switches photos so a long
    /// browsing session doesn't accumulate intermediates.
    public func clearCaches() {
        context.clearCaches()
    }

    static func clampQuality(_ quality: Double) -> Double {
        guard quality.isFinite else { return 0.9 }
        return min(max(quality, 0), 1)
    }

    /// Spec §10: "disk full" must be reported as itself, not as a generic
    /// failure that leaves the user guessing.
    static func mapWriteError(_ error: Error, url: URL) -> Error {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteOutOfSpaceError {
            return ImageRenderError.insufficientDiskSpace
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOSPC) {
            return ImageRenderError.insufficientDiskSpace
        }
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteNoPermissionError {
            return ImageRenderError.destinationNotWritable(path: url.deletingLastPathComponent().path)
        }
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(EACCES) || nsError.code == Int(EROFS) {
            return ImageRenderError.destinationNotWritable(path: url.deletingLastPathComponent().path)
        }
        return error
    }
}
