import Foundation
import Localization
import PhotoLibraryCore
import RawProcessingCore

/// View-facing, display-ready snapshot of a photo's metadata for the Mac
/// editor's metadata/EXIF panel (AwayPhotoRawEditor parity design spec
/// §6.2). Every field is already formatted for display, or `nil` when the
/// underlying `RawMetadata` is missing that value -- a caller never touches
/// `RawMetadata`'s raw numeric fields or the photo's on-disk URL directly,
/// so a private absolute source path can never reach the UI through this
/// type, and a missing field can never crash the panel.
public struct EditorMetadataSnapshot: Equatable, Sendable {
    public var filename: String
    public var formatDescription: String
    public var pixelDimensions: String?
    public var fileSizeDescription: String?
    public var cameraDescription: String?
    public var lensDescription: String?
    public var focalLengthDescription: String?
    public var apertureDescription: String?
    public var shutterSpeedDescription: String?
    public var isoDescription: String?
    public var captureDateDescription: String?
    public var orientationDescription: String?

    public init(photo: PhotoAsset) {
        let metadata = photo.metadata
        filename = photo.filename
        formatDescription = Self.formatDescription(forFilename: photo.filename)
        pixelDimensions = Self.pixelDimensions(width: metadata.pixelWidth, height: metadata.pixelHeight)
        fileSizeDescription = Self.fileSizeDescription(bytes: photo.fingerprint.fileSize)
        cameraDescription = metadata.cameraDisplayName
        lensDescription = metadata.lensModel
        focalLengthDescription = metadata.focalLengthMillimeters.map(Self.focalLengthDescription(millimeters:))
        apertureDescription = metadata.aperture.map(Self.apertureDescription(fNumber:))
        shutterSpeedDescription = metadata.shutterSpeed.map(Self.shutterSpeedDescription(seconds:))
        isoDescription = metadata.isoSpeed.map { "ISO \($0)" }
        captureDateDescription = metadata.captureDate.map { Self.captureDateFormatter.string(from: $0) }
        orientationDescription = metadata.orientation.map(String.init)
    }

    /// `photo.filename` is already the basename `PhotoAsset` itself derives
    /// from `relativePath` -- an extension here would only need to change if
    /// that guarantee ever moved, not re-derive it.
    private static func formatDescription(forFilename filename: String) -> String {
        let extensionText = (filename as NSString).pathExtension
        guard !extensionText.isEmpty else { return L10n.t("Unknown") }
        return extensionText.uppercased()
    }

    private static func pixelDimensions(width: Int, height: Int) -> String? {
        guard width > 0, height > 0 else { return nil }
        return "\(width) × \(height)"
    }

    private static func fileSizeDescription(bytes: Int64) -> String? {
        guard bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func focalLengthDescription(millimeters: Double) -> String {
        let formatted = decimalFormatter.string(from: NSNumber(value: millimeters)) ?? String(millimeters)
        return "\(formatted) mm"
    }

    private static func apertureDescription(fNumber: Double) -> String {
        let formatted = decimalFormatter.string(from: NSNumber(value: fNumber)) ?? String(fNumber)
        return "f/\(formatted)"
    }

    /// Sub-second exposures read far more naturally as a fraction ("1/125 s")
    /// than a repeating decimal; whole-and-longer exposures read naturally
    /// as a decimal ("2 s", "0.5 s" never occurs here since anything under a
    /// second takes the fraction branch).
    private static func shutterSpeedDescription(seconds: Double) -> String {
        guard seconds > 0 else { return "0 s" }
        if seconds >= 1 {
            let formatted = decimalFormatter.string(from: NSNumber(value: seconds)) ?? String(seconds)
            return "\(formatted) s"
        }
        let denominator = Int((1 / seconds).rounded())
        return "1/\(denominator) s"
    }

    private static let decimalFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        return formatter
    }()

    private static let captureDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
