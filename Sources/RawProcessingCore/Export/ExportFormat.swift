import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Localization
import UniformTypeIdentifiers

/// Every output format single-photo export can produce (design spec §6.11).
///
/// Batch export, watermarking and rename templates are later phases; this is
/// the format-aware foundation Phase 1 Task 4 asks for.
public enum ExportFormat: String, CaseIterable, Equatable, Sendable {
    case jpeg
    case png
    case tiff
    case heic

    public var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .png: return "png"
        case .tiff: return "tiff"
        case .heic: return "heic"
        }
    }

    public var utTypeIdentifier: String {
        switch self {
        case .jpeg: return UTType.jpeg.identifier
        case .png: return UTType.png.identifier
        case .tiff: return UTType.tiff.identifier
        case .heic: return UTType.heic.identifier
        }
    }

    /// JPEG and HEIC are lossy; PNG and TIFF are lossless in this foundation
    /// version, so a quality slider bound to either would be a lie.
    public var usesQuality: Bool {
        switch self {
        case .jpeg, .heic: return true
        case .png, .tiff: return false
        }
    }

    /// Spec §6.11 only calls out "TIFF 8-bit / 16-bit" -- no other format
    /// gets a bit-depth choice in this foundation version.
    public var supportsBitDepthChoice: Bool {
        self == .tiff
    }

    public var displayName: String {
        switch self {
        case .jpeg: return L10n.t("JPEG")
        case .png: return L10n.t("PNG")
        case .tiff: return L10n.t("TIFF")
        case .heic: return L10n.t("HEIC")
        }
    }

    /// Whether this build can actually encode this format -- checked against
    /// an injectable set so a platform without an encoder for one format
    /// (e.g. no HEIC codec) can be simulated in tests rather than only ever
    /// passing on whatever machine happens to run the suite.
    public func isSupported(by encodableTypeIdentifiers: Set<String> = ExportFormat.systemEncodableTypeIdentifiers()) -> Bool {
        encodableTypeIdentifiers.contains(utTypeIdentifier)
    }

    public static func systemEncodableTypeIdentifiers() -> Set<String> {
        Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
    }
}

/// TIFF's 8-bit/16-bit-per-channel export choice (design spec §6.11).
/// Ignored by every format that doesn't set `ExportFormat.supportsBitDepthChoice`.
public enum ExportBitDepth: String, CaseIterable, Equatable, Sendable {
    case eightBit
    case sixteenBit

    /// The `CIFormat` that produces this many bits per channel when the
    /// rendered `CGImage`/representation is created.
    public var pixelFormat: CIFormat {
        switch self {
        case .eightBit: return .RGBA8
        case .sixteenBit: return .RGBA16
        }
    }

    public var displayName: String {
        switch self {
        case .eightBit: return L10n.t("8-bit")
        case .sixteenBit: return L10n.t("16-bit")
        }
    }
}
