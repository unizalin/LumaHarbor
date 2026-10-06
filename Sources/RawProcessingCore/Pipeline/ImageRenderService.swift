import CoreGraphics
import Localization
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
            return L10n.t("The image couldn't be rendered.")
        case .encodingFailed:
            return L10n.t("The JPEG couldn't be encoded.")
        case .insufficientDiskSpace:
            return L10n.t("There isn't enough free space to finish writing the file.")
        case .destinationNotWritable:
            return L10n.t("That location can't be written to.")
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .insufficientDiskSpace:
            return L10n.t("Free up space or choose a different destination, then export again.")
        case .destinationNotWritable:
            return L10n.t("Choose a different output location.")
        case .renderFailed, .encodingFailed:
            return L10n.t("Try exporting again.")
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
    private let preferMetal: Bool
    public let workingColorSpaceID: String
    public let outputTransformID: String

    /// Uses the default Metal device when one exists. Falling back to the CPU
    /// context keeps unit tests runnable on machines without a usable GPU
    /// (headless CI, for instance) instead of crashing at init.
    public init(preferMetal: Bool = true, recipe: ResolvedRawRenderRecipe? = nil) {
        self.preferMetal = preferMetal
        self.workingColorSpaceID = recipe?.workingColorSpaceID
            ?? RawWorkingColorSpaceID.nativeExtendedLinearSRGBV1.rawValue
        self.outputTransformID = recipe?.outputTransformID
            ?? RawOutputTransformID.displaySRGBV1.rawValue
        let workingColorSpace = RawColorSpaceCatalog.workingColorSpace(for: workingColorSpaceID)
        let outputColorSpace = RawColorSpaceCatalog.outputColorSpace(for: outputTransformID)
        let options: [CIContextOption: Any] = [
            .workingColorSpace: workingColorSpace,
            .outputColorSpace: outputColorSpace,
            .cacheIntermediates: false
        ]
        if preferMetal, let device = MTLCreateSystemDefaultDevice() {
            self.context = CIContext(mtlDevice: device, options: options)
        } else {
            self.context = CIContext(options: options)
        }
    }

    /// Source and ABI compatibility for callers compiled against the
    /// pre-recipe initializer.
    public convenience init(preferMetal: Bool) {
        self.init(preferMetal: preferMetal, recipe: nil)
    }

    /// Creates a service with the same device preference but the recipe's
    /// versioned color-space configuration. This keeps the injected service
    /// used by tests and callers while ensuring preview/export do not infer a
    /// different transform from their call site.
    public func configured(for recipe: ResolvedRawRenderRecipe) -> ImageRenderService {
        if recipe.workingColorSpaceID == workingColorSpaceID,
           recipe.outputTransformID == outputTransformID {
            return self
        }
        return ImageRenderService(preferMetal: preferMetal, recipe: recipe)
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
            colorSpace: RawColorSpaceCatalog.outputColorSpace(for: outputTransformID)
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
            colorSpace: RawColorSpaceCatalog.outputColorSpace(for: outputTransformID),
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
                colorSpace: RawColorSpaceCatalog.outputColorSpace(for: outputTransformID),
                options: options
            )
        } catch {
            throw Self.mapWriteError(error, url: url)
        }
    }

    /// Format-aware single-photo export write (design spec §6.11): JPEG,
    /// PNG, TIFF or HEIC, with quality (JPEG/HEIC only), bit depth (TIFF
    /// only), DPI metadata and an EXIF/TIFF properties dictionary.
    ///
    /// Goes through `CGImageDestination` directly rather than `CIContext`'s
    /// `...Representation` convenience methods: those only honor a small
    /// documented allowlist of `CIImageRepresentationOption`s (compression
    /// quality among them) and silently drop arbitrary ImageIO property
    /// keys like `kCGImagePropertyTIFFDictionary` or `kCGImagePropertyDPIWidth`
    /// -- confirmed by hand, the exact reason `writeJPEG(_:to:quality:)`
    /// above can't simply grow more options. `CGImageDestinationAddImage`'s
    /// properties dictionary is the documented, general mechanism for
    /// writing this metadata, for every format ImageIO can encode.
    public func writeExport(
        _ image: CIImage,
        to url: URL,
        format: ExportFormat,
        quality: Double,
        bitDepth: ExportBitDepth,
        dpi: Double?,
        exifProperties: [CFString: Any]
    ) throws {
        guard !image.extent.isInfinite, !image.extent.isEmpty else {
            throw ImageRenderError.renderFailed
        }

        let pixelFormat: CIFormat = format.supportsBitDepthChoice ? bitDepth.pixelFormat : .RGBA8
        guard let renderedImage = context.createCGImage(
            image,
            from: image.extent,
            format: pixelFormat,
            colorSpace: RawColorSpaceCatalog.outputColorSpace(for: outputTransformID)
        ) else {
            throw ImageRenderError.renderFailed
        }

        // Lightroom's 16-bit reference TIFFs are RGB, not RGBA. Core Image's
        // RGBA16 render format is intentionally used above to preserve the
        // existing render path, then the TIFF-only container conversion drops
        // the synthetic alpha channel without changing colour values.
        let cgImage: CGImage
        if format == .tiff {
            guard let rgbImage = Self.rgbImageWithoutAlpha(
                renderedImage,
                colorSpace: RawColorSpaceCatalog.outputColorSpace(for: outputTransformID)
            ) else {
                throw ImageRenderError.renderFailed
            }
            cgImage = rgbImage
        } else {
            cgImage = renderedImage
        }

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, format.utTypeIdentifier as CFString, 1, nil
        ) else {
            throw ImageRenderError.destinationNotWritable(path: url.deletingLastPathComponent().path)
        }

        var properties = exifProperties
        if format.usesQuality {
            properties[kCGImageDestinationLossyCompressionQuality] = Self.clampQuality(quality)
        }
        if let dpi {
            properties[kCGImagePropertyDPIWidth] = dpi
            properties[kCGImagePropertyDPIHeight] = dpi
        }

        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageRenderError.encodingFailed
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

    private static func rgbImageWithoutAlpha(
        _ image: CGImage,
        colorSpace: CGColorSpace
    ) -> CGImage? {
        guard image.bitsPerComponent == 8 || image.bitsPerComponent == 16 else { return nil }

        let bytesPerSample = image.bitsPerComponent / 8
        // `noneSkipLast` keeps a native 4-sample row layout that Core
        // Graphics accepts for both 8- and 16-bit contexts, while explicitly
        // marking the fourth sample as padding rather than an alpha channel.
        // ImageIO therefore writes an RGB TIFF without resampling the three
        // colour channels into a different precision.
        let bytesPerRow = image.width * 4 * bytesPerSample
        var bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue
        if image.bitsPerComponent == 16 {
            bitmapInfo |= CGBitmapInfo.byteOrder16Big.rawValue
        }

        guard let bitmapContext = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: image.bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        bitmapContext.interpolationQuality = .none
        bitmapContext.draw(
            image,
            in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        return bitmapContext.makeImage()
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
