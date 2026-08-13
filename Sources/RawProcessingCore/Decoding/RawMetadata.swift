import Foundation
import ImageIO

/// EXIF summary the library browser shows and the SQLite index caches.
///
/// Codable so the index can be rebuilt from it and so tests can round-trip it
/// without a real RAW file.
public struct RawMetadata: Codable, Equatable, Sendable {
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var captureDate: Date?
    public var cameraMake: String?
    public var cameraModel: String?
    public var lensModel: String?
    public var isoSpeed: Int?
    /// Exposure time in seconds.
    public var shutterSpeed: Double?
    public var aperture: Double?
    /// TIFF orientation, 1...8.
    public var orientation: Int?

    public init(
        pixelWidth: Int = 0,
        pixelHeight: Int = 0,
        captureDate: Date? = nil,
        cameraMake: String? = nil,
        cameraModel: String? = nil,
        lensModel: String? = nil,
        isoSpeed: Int? = nil,
        shutterSpeed: Double? = nil,
        aperture: Double? = nil,
        orientation: Int? = nil
    ) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.captureDate = captureDate
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.lensModel = lensModel
        self.isoSpeed = isoSpeed
        self.shutterSpeed = shutterSpeed
        self.aperture = aperture
        self.orientation = orientation
    }

    public var cameraDisplayName: String? {
        switch (cameraMake, cameraModel) {
        case let (make?, model?):
            // Sony writes "SONY" into Make and "ILCE-7M4" into Model; joining them
            // blindly gives "SONY SONY ILCE-7M4" for some bodies.
            return model.hasPrefix(make) ? model : "\(make) \(model)"
        case let (nil, model?):
            return model
        case let (make?, nil):
            return make
        case (nil, nil):
            return nil
        }
    }
}

extension RawMetadata {
    /// Parses the CGImageSource property dictionary. Kept separate from the
    /// decoder so it can be tested against a literal dictionary.
    public static func from(imageProperties properties: [CFString: Any]) -> RawMetadata {
        var metadata = RawMetadata()

        metadata.pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        metadata.pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        metadata.orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue

        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            metadata.cameraMake = (tiff[kCGImagePropertyTIFFMake] as? String)?
                .trimmingCharacters(in: .whitespaces)
            metadata.cameraModel = (tiff[kCGImagePropertyTIFFModel] as? String)?
                .trimmingCharacters(in: .whitespaces)
        }

        if let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                metadata.captureDate = exifDateFormatter.date(from: raw)
            }
            if let isoValues = exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber] {
                metadata.isoSpeed = isoValues.first?.intValue
            }
            metadata.shutterSpeed = (exif[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue
            metadata.aperture = (exif[kCGImagePropertyExifFNumber] as? NSNumber)?.doubleValue
            if let lens = exif[kCGImagePropertyExifLensModel] as? String {
                metadata.lensModel = lens.trimmingCharacters(in: .whitespaces)
            }
        }

        // Some Sony bodies only carry the capture date in the DNG/TIFF block.
        if metadata.captureDate == nil,
           let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let raw = tiff[kCGImagePropertyTIFFDateTime] as? String {
            metadata.captureDate = exifDateFormatter.date(from: raw)
        }

        return metadata
    }

    /// EXIF stores local wall-clock time with no zone. Parsing in the current
    /// time zone matches what the camera's clock meant to the photographer.
    private static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()
}
