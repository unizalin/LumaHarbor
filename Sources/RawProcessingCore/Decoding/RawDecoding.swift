import CoreImage
import Foundation

/// White balance expressed as an offset from whatever the file recorded.
///
/// Offsets rather than absolutes so the same sidecar produces a sensible result
/// on any decoder: a `LibRawDecoder` added later reports its own as-shot neutral
/// and applies the same delta.
public struct RawWhiteBalance: Equatable, Sendable {
    public var temperatureOffsetKelvin: Double
    public var tintOffset: Double

    public init(temperatureOffsetKelvin: Double = 0, tintOffset: Double = 0) {
        self.temperatureOffsetKelvin = temperatureOffsetKelvin
        self.tintOffset = tintOffset
    }

    public static let asShot = RawWhiteBalance()

    public var isAsShot: Bool { self == .asShot }
}

/// How much work the decoder should do.
///
/// Spec §9: previews decode at display size, exports re-decode at full size.
public enum DecodeQuality: Equatable, Sendable {
    /// Small, draft-mode decode for grid and filmstrip cells.
    case thumbnail(maximumPixelDimension: Int)
    /// Screen-sized draft decode that keeps slider dragging responsive.
    case interactive(maximumPixelDimension: Int)
    /// Screen-sized decode with draft mode off, scheduled once input settles.
    case highQuality(maximumPixelDimension: Int)
    /// Native resolution, draft mode off. Export only.
    case full

    public var maximumPixelDimension: Int? {
        switch self {
        case .thumbnail(let value), .interactive(let value), .highQuality(let value):
            return value
        case .full:
            return nil
        }
    }

    public var allowsDraftMode: Bool {
        switch self {
        case .thumbnail, .interactive: return true
        case .highQuality, .full: return false
        }
    }
}

public struct RawDecodeRequest: Equatable, Sendable {
    public var url: URL
    public var quality: DecodeQuality
    public var whiteBalance: RawWhiteBalance

    public init(
        url: URL,
        quality: DecodeQuality = .full,
        whiteBalance: RawWhiteBalance = .asShot
    ) {
        self.url = url
        self.quality = quality
        self.whiteBalance = whiteBalance
    }
}

/// Identifies which decoder produced an edit, recorded in the sidecar so a
/// future decoder swap is visible rather than silent.
public struct DecoderIdentifier: Codable, Equatable, Sendable {
    public var kind: String
    public var version: String

    public init(kind: String, version: String) {
        self.kind = kind
        self.version = version
    }
}

/// A decoded RAW ready for the adjustment chain.
///
/// `image` is in the decoder's linear working space; the pipeline owns every
/// transform after this point.
public struct DecodedRawImage: @unchecked Sendable {
    public let image: CIImage
    /// Native full-resolution pixel size, regardless of the decode quality used.
    public let nativePixelSize: CGSize
    /// Pixel size of `image`, which is smaller than native for scaled decodes.
    public let decodedPixelSize: CGSize
    /// As-shot neutral the decoder started from, before the request's offsets.
    public let baselineTemperature: Double
    public let baselineTint: Double
    public let metadata: RawMetadata

    public init(
        image: CIImage,
        nativePixelSize: CGSize,
        decodedPixelSize: CGSize,
        baselineTemperature: Double,
        baselineTint: Double,
        metadata: RawMetadata
    ) {
        self.image = image
        self.nativePixelSize = nativePixelSize
        self.decodedPixelSize = decodedPixelSize
        self.baselineTemperature = baselineTemperature
        self.baselineTint = baselineTint
        self.metadata = metadata
    }

    /// How far `image` has been downscaled from native, by longest edge —
    /// `1` for a full-resolution decode, `<1` for a downsampled
    /// interactive/preview decode. Feeds `AdjustmentPipeline.apply(...
    /// scaleFactor:)` (spec §7 Gate B3) so pixel-radius adjustments (sharpen,
    /// grain) read consistently between preview and export.
    public var scaleFactor: Double {
        let nativeLongestEdge = Double(max(nativePixelSize.width, nativePixelSize.height))
        guard nativeLongestEdge > 0 else { return 1 }
        let decodedLongestEdge = Double(max(decodedPixelSize.width, decodedPixelSize.height))
        return decodedLongestEdge / nativeLongestEdge
    }
}

/// The seam that keeps Core Image swappable.
///
/// Spec §4: the UI, sidecar and edit-state models must not change when a
/// `LibRawDecoder` is added, so nothing outside `RawProcessingCore` may touch
/// `CIRAWFilter` directly.
public protocol RawDecoding: Sendable {
    var identifier: DecoderIdentifier { get }

    /// Cheap check used by the scanner to decide whether a file is worth
    /// indexing as a photo. Must not throw for unreadable files.
    func supportsFile(at url: URL) -> Bool

    func readMetadata(at url: URL) throws -> RawMetadata

    func decode(_ request: RawDecodeRequest) throws -> DecodedRawImage
}
