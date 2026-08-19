import CoreImage
import Foundation
import ImageIO

/// The MVP decoder: Apple's `CIRAWFilter`.
///
/// It is the only type in the project allowed to construct a `CIRAWFilter`
/// (spec §5.1). White balance is applied here rather than in the adjustment
/// chain because for a RAW file the neutral point belongs to demosaicing — a
/// `CITemperatureAndTint` after the fact would fight the decoder's own
/// rendering.
public struct CoreImageRawDecoder: RawDecoding {
    public let identifier = DecoderIdentifier(kind: "coreImage", version: "system-default")

    public init() {}

    public func supportsFile(at url: URL) -> Bool {
        // `CIRAWFilter(imageURL:)` itself is lazy: it returns non-nil for a
        // missing file or for garbage bytes alike, deferring any real
        // validation to `nativeSize`/`outputImage`. `nativeSize` is the same
        // signal `decode(_:)` already uses to detect a corrupted file, so it
        // is what actually answers "is this a supported RAW".
        guard let filter = CIRAWFilter(imageURL: url) else { return false }
        let size = filter.nativeSize
        return size.width > 0 && size.height > 0
    }

    public func readMetadata(at url: URL) throws -> RawMetadata {
        let source = try makeImageSource(for: url)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any] else {
            throw RawDecodingError.corruptedFile(path: url.path)
        }
        return RawMetadata.from(imageProperties: properties)
    }

    public func decode(_ request: RawDecodeRequest) throws -> DecodedRawImage {
        let url = request.url

        // Establish *why* a decode would fail before asking CIRAWFilter, which
        // returns a bare nil for "missing", "damaged" and "unsupported" alike.
        let source = try makeImageSource(for: url)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]

        guard let filter = CIRAWFilter(imageURL: url) else {
            throw RawDecodingError.unsupportedFormat(path: url.path)
        }

        let nativeSize = filter.nativeSize
        guard nativeSize.width > 0, nativeSize.height > 0 else {
            throw RawDecodingError.corruptedFile(path: url.path)
        }

        // Read the as-shot neutral before overwriting it, so the sidecar's
        // offsets stay relative to what the camera recorded.
        let baselineTemperature = Double(filter.neutralTemperature)
        let baselineTint = Double(filter.neutralTint)

        if !request.whiteBalance.isAsShot {
            filter.neutralTemperature = Float(baselineTemperature + request.whiteBalance.temperatureOffsetKelvin)
            filter.neutralTint = Float(baselineTint + request.whiteBalance.tintOffset)
        }

        let scaleFactor = Self.scaleFactor(
            nativeSize: nativeSize,
            maximumPixelDimension: request.quality.maximumPixelDimension
        )
        filter.scaleFactor = Float(scaleFactor)
        filter.isDraftModeEnabled = request.quality.allowsDraftMode

        guard let output = filter.outputImage else {
            throw RawDecodingError.decodeFailed(
                path: url.path,
                reason: String(localized: "The system RAW decoder returned no image.")
            )
        }

        var metadata = properties.map(RawMetadata.from(imageProperties:)) ?? RawMetadata()
        if metadata.pixelWidth == 0 || metadata.pixelHeight == 0 {
            metadata.pixelWidth = Int(nativeSize.width.rounded())
            metadata.pixelHeight = Int(nativeSize.height.rounded())
        }

        return DecodedRawImage(
            image: output,
            nativePixelSize: nativeSize,
            decodedPixelSize: output.extent.size,
            baselineTemperature: baselineTemperature,
            baselineTint: baselineTint,
            metadata: metadata
        )
    }

    // MARK: - Helpers

    /// Longest-edge fit, never upscaling. `nil` (export) keeps native size.
    static func scaleFactor(nativeSize: CGSize, maximumPixelDimension: Int?) -> Double {
        guard let maximum = maximumPixelDimension, maximum > 0 else { return 1 }
        let longestEdge = Double(max(nativeSize.width, nativeSize.height))
        guard longestEdge > 0 else { return 1 }
        return min(1, Double(maximum) / longestEdge)
    }

    private func makeImageSource(for url: URL) throws -> CGImageSource {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RawDecodingError.fileUnavailable(path: url.path)
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw RawDecodingError.fileUnavailable(path: url.path)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw RawDecodingError.corruptedFile(path: url.path)
        }
        return source
    }
}

extension CoreImageRawDecoder {
    /// File extensions the scanner treats as candidate RAWs.
    ///
    /// This is a fast pre-filter only — `supportsFile(at:)` still decides. Sony
    /// `.ARW` is the MVP's required format; the rest are here because
    /// `CIRAWFilter` handles them and excluding them would be arbitrary.
    public static let candidateFileExtensions: Set<String> = [
        "arw", "sr2", "srf",           // Sony
        "cr2", "cr3", "crw",           // Canon
        "nef", "nrw",                  // Nikon
        "raf",                         // Fujifilm
        "orf",                         // Olympus / OM System
        "rw2",                         // Panasonic
        "pef",                         // Pentax
        "dng",                         // Adobe / Apple ProRAW
        "erf", "3fr", "fff", "iiq",    // Epson, Hasselblad, Phase One
        "gpr"                          // GoPro
    ]
}
