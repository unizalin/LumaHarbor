import CoreGraphics
import Foundation

public enum RawWorkingColorSpaceID: String, Codable, Hashable, Sendable {
    case nativeExtendedLinearSRGBV1 = "extended-linear-srgb-v1"
    case adobeCompatibleLinearWideGamutV1 = "adobe-compatible-linear-wide-gamut-v1"
}

public enum RawOutputTransformID: String, Codable, Hashable, Sendable {
    case displaySRGBV1 = "srgb-output-v1"
    case referenceTIFFSRGB16V1 = "reference-tiff-srgb-16-v1"
}

/// One source of truth for the working and output color spaces used by both
/// preview and export. The IDs are versioned so a future calibration can be
/// introduced without silently changing old RAW renders.
public enum RawColorSpaceCatalog {
    public static func workingColorSpace(for id: RawWorkingColorSpaceID) -> CGColorSpace {
        switch id {
        case .nativeExtendedLinearSRGBV1:
            return CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
                ?? CGColorSpaceCreateDeviceRGB()
        case .adobeCompatibleLinearWideGamutV1:
            return CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
                ?? CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
                ?? CGColorSpaceCreateDeviceRGB()
        }
    }

    public static func outputColorSpace(for id: RawOutputTransformID) -> CGColorSpace {
        switch id {
        case .displaySRGBV1, .referenceTIFFSRGB16V1:
            return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        }
    }

    public static func workingColorSpace(for rawValue: String) -> CGColorSpace {
        let id = RawWorkingColorSpaceID(rawValue: rawValue) ?? .nativeExtendedLinearSRGBV1
        return workingColorSpace(for: id)
    }

    public static func outputColorSpace(for rawValue: String) -> CGColorSpace {
        let id = RawOutputTransformID(rawValue: rawValue) ?? .displaySRGBV1
        return outputColorSpace(for: id)
    }
}
