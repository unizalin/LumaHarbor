import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ReferenceImageMetadataExpectation: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let bitsPerComponent: Int
    public let colorSpaceIdentifier: String
    public let hasAlpha: Bool

    public init(
        width: Int,
        height: Int,
        bitsPerComponent: Int,
        colorSpaceIdentifier: String,
        hasAlpha: Bool
    ) {
        self.width = width
        self.height = height
        self.bitsPerComponent = bitsPerComponent
        self.colorSpaceIdentifier = colorSpaceIdentifier
        self.hasAlpha = hasAlpha
    }
}

public struct ReferenceImageMetadata: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let bitsPerComponent: Int
    public let colorSpaceIdentifier: String
    public let profileName: String
    public let hasAlpha: Bool

    public init(
        width: Int,
        height: Int,
        bitsPerComponent: Int,
        colorSpaceIdentifier: String,
        profileName: String,
        hasAlpha: Bool
    ) {
        self.width = width
        self.height = height
        self.bitsPerComponent = bitsPerComponent
        self.colorSpaceIdentifier = colorSpaceIdentifier
        self.profileName = profileName
        self.hasAlpha = hasAlpha
    }
}

public enum ReferenceImageMetadataValidationError: Error, Equatable, Hashable, Sendable {
    case invalidSource
    case unsupportedFormat
    case missingEmbeddedProfile
    case unsupportedColorSpace
    case invalidDimensions
    case invalidBitDepth
    case dimensionMismatch
    case colorSpaceMismatch
    case alphaMismatch
}

public enum ReferenceImageMetadataValidator {
    public static func validate(
        imageAt url: URL,
        against expectation: ReferenceImageMetadataExpectation
    ) throws -> ReferenceImageMetadata {
        guard expectation.width > 0, expectation.height > 0 else {
            throw ReferenceImageMetadataValidationError.invalidDimensions
        }
        let metadata = try read(from: url)
        guard metadata.width == expectation.width, metadata.height == expectation.height else {
            throw ReferenceImageMetadataValidationError.dimensionMismatch
        }
        guard metadata.bitsPerComponent == expectation.bitsPerComponent,
              metadata.bitsPerComponent >= 16 else {
            throw ReferenceImageMetadataValidationError.invalidBitDepth
        }
        guard metadata.colorSpaceIdentifier == expectation.colorSpaceIdentifier else {
            throw ReferenceImageMetadataValidationError.colorSpaceMismatch
        }
        guard metadata.hasAlpha == expectation.hasAlpha else {
            throw ReferenceImageMetadataValidationError.alphaMismatch
        }
        return metadata
    }

    public static func read(from url: URL) throws -> ReferenceImageMetadata {
        guard url.isFileURL,
              FileManager.default.fileExists(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ReferenceImageMetadataValidationError.invalidSource
        }
        guard let sourceType = CGImageSourceGetType(source),
              UTType(sourceType as String)?.conforms(to: .tiff) == true else {
            throw ReferenceImageMetadataValidationError.unsupportedFormat
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let profileName = properties[kCGImagePropertyProfileName] as? String else {
            throw ReferenceImageMetadataValidationError.missingEmbeddedProfile
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ReferenceImageMetadataValidationError.invalidSource
        }
        guard image.width > 0, image.height > 0 else {
            throw ReferenceImageMetadataValidationError.invalidDimensions
        }
        guard let colorSpaceName = image.colorSpace?.name as String? else {
            throw ReferenceImageMetadataValidationError.unsupportedColorSpace
        }
        guard colorSpaceName == CGColorSpace.sRGB as String,
              profileName == "sRGB IEC61966-2.1" else {
            throw ReferenceImageMetadataValidationError.unsupportedColorSpace
        }

        return ReferenceImageMetadata(
            width: image.width,
            height: image.height,
            bitsPerComponent: image.bitsPerComponent,
            colorSpaceIdentifier: colorSpaceName,
            profileName: profileName,
            hasAlpha: alphaInfoHasChannel(image.alphaInfo)
        )
    }

    private static func alphaInfoHasChannel(_ alphaInfo: CGImageAlphaInfo) -> Bool {
        switch alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        case .alphaOnly, .first, .last, .premultipliedFirst, .premultipliedLast:
            return true
        @unknown default:
            return true
        }
    }
}
