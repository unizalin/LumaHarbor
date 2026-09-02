import Foundation
import ImageIO

/// Builds the ImageIO properties dictionary an exported file's EXIF/TIFF
/// block is written from, out of what LumaHarbor already knows about the
/// source (`RawMetadata`). Nothing here reads a RAW file's own embedded
/// EXIF/GPS block directly, so this stays a pure, offline-testable function
/// with no decoder dependency -- the mirror image of the existing
/// `RawMetadata.from(imageProperties:)` decode-side parser.
public enum ExportMetadataBuilder {
    public static func imageProperties(from metadata: RawMetadata) -> [CFString: Any] {
        var properties: [CFString: Any] = [:]

        var tiff: [CFString: Any] = [:]
        if let make = metadata.cameraMake { tiff[kCGImagePropertyTIFFMake] = make }
        if let model = metadata.cameraModel { tiff[kCGImagePropertyTIFFModel] = model }
        if !tiff.isEmpty { properties[kCGImagePropertyTIFFDictionary] = tiff }

        var exif: [CFString: Any] = [:]
        if let iso = metadata.isoSpeed { exif[kCGImagePropertyExifISOSpeedRatings] = [iso] }
        if let shutter = metadata.shutterSpeed { exif[kCGImagePropertyExifExposureTime] = shutter }
        if let aperture = metadata.aperture { exif[kCGImagePropertyExifFNumber] = aperture }
        if let focalLength = metadata.focalLengthMillimeters { exif[kCGImagePropertyExifFocalLength] = focalLength }
        if let lens = metadata.lensModel { exif[kCGImagePropertyExifLensModel] = lens }
        if let captureDate = metadata.captureDate {
            exif[kCGImagePropertyExifDateTimeOriginal] = exifDateFormatter.string(from: captureDate)
        }
        if !exif.isEmpty { properties[kCGImagePropertyExifDictionary] = exif }

        if let orientation = metadata.orientation { properties[kCGImagePropertyOrientation] = orientation }

        return properties
    }

    /// Same format `RawMetadata.from(imageProperties:)` parses on the decode
    /// side (EXIF's local-wall-clock-time-with-no-zone convention).
    private static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()
}
