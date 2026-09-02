import Foundation
import Localization

/// How much of a photo's own metadata single-photo export carries into the
/// output file (design spec §6.11: "EXIF 保留、移除或部分保留").
///
/// A pure `RawMetadata -> RawMetadata` transform rather than something that
/// touches ImageIO or a real file directly, so it's testable with no decoder
/// and no CGImageDestination. `ExportMetadataBuilder` turns whatever survives
/// into the properties dictionary an exported file is actually written with.
public enum ExifRetentionPolicy: String, CaseIterable, Equatable, Sendable {
    case preserveAll
    case removeAll
    /// Strips what's traceable to *when and with what* the photo was taken
    /// (capture date, camera, lens) while keeping the generic exposure/
    /// technical fields (ISO, shutter, aperture, focal length, orientation).
    /// `RawMetadata` has no GPS field to strip, so this is a deliberate,
    /// documented reading of "partial" rather than a location-only policy.
    case partial

    public var displayName: String {
        switch self {
        case .preserveAll: return L10n.t("Preserve all")
        case .removeAll: return L10n.t("Remove all")
        case .partial: return L10n.t("Partial (remove camera & date)")
        }
    }

    /// Pixel dimensions are never metadata the user is trying to strip --
    /// they're what the file *is* -- so every policy leaves them untouched.
    public func apply(to metadata: RawMetadata) -> RawMetadata {
        switch self {
        case .preserveAll:
            return metadata
        case .removeAll:
            return RawMetadata(pixelWidth: metadata.pixelWidth, pixelHeight: metadata.pixelHeight)
        case .partial:
            var stripped = metadata
            stripped.captureDate = nil
            stripped.cameraMake = nil
            stripped.cameraModel = nil
            stripped.lensModel = nil
            return stripped
        }
    }
}
