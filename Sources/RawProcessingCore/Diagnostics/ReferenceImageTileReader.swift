import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ReferenceImageTile: Sendable {
    public let originY: Int
    public let width: Int
    public let height: Int
    public let rgba16: [UInt16]

    public init(originY: Int, width: Int, height: Int, rgba16: [UInt16]) {
        self.originY = originY
        self.width = width
        self.height = height
        self.rgba16 = rgba16
    }
}

/// Reads encoded-sRGB TIFF rows without creating a full floating-point pixel
/// buffer. The backing CGImage remains owned by ImageIO/CoreGraphics while
/// callers hold only the current 16-bit tile.
public struct ReferenceImageTileReader {
    public let width: Int
    public let height: Int
    public let bitsPerComponent: Int
    public let colorSpaceIdentifier: String
    public let hasAlpha: Bool

    private let image: CGImage

    public init(url: URL) throws {
        guard url.isFileURL,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ReferenceImageBufferError.invalidSource
        }
        guard let sourceType = CGImageSourceGetType(source),
              UTType(sourceType as String)?.conforms(to: .tiff) == true else {
            throw ReferenceImageBufferError.unsupportedFormat
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let profileName = properties[kCGImagePropertyProfileName] as? String,
              profileName == "sRGB IEC61966-2.1" else {
            throw ReferenceImageBufferError.missingColorSpace
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0,
              image.height > 0 else {
            throw ReferenceImageBufferError.decodeFailed
        }
        guard image.bitsPerComponent >= 16 else {
            throw ReferenceImageBufferError.invalidBitDepth(image.bitsPerComponent)
        }
        guard let colorSpaceName = image.colorSpace?.name as String?,
              colorSpaceName == CGColorSpace.sRGB as String else {
            throw ReferenceImageBufferError.unsupportedColorSpace
        }

        self.width = image.width
        self.height = image.height
        self.bitsPerComponent = image.bitsPerComponent
        self.colorSpaceIdentifier = colorSpaceName
        self.hasAlpha = Self.alphaInfoHasChannel(image.alphaInfo)
        self.image = image
    }

    public func tile(startRow: Int, rowCount: Int) throws -> ReferenceImageTile {
        guard startRow >= 0,
              rowCount > 0,
              startRow <= height,
              rowCount <= height - startRow else {
            throw ReferenceImageBufferError.invalidDimensions
        }

        // The public row contract is top-to-bottom. CGImage crop coordinates
        // are bottom-to-top, so translate the requested range explicitly.
        let cropRect = CGRect(
            x: 0,
            y: height - startRow - rowCount,
            width: width,
            height: rowCount
        )
        guard let cropped = image.cropping(to: cropRect) else {
            throw ReferenceImageBufferError.decodeFailed
        }

        let componentCount = 4
        var samples = [UInt16](repeating: 0, count: width * rowCount * componentCount)
        let bitmapInfo = CGBitmapInfo.byteOrder16Little.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: &samples,
            width: width,
            height: rowCount,
            bitsPerComponent: 16,
            bytesPerRow: width * componentCount * MemoryLayout<UInt16>.size,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: bitmapInfo
        ) else {
            throw ReferenceImageBufferError.decodeFailed
        }
        context.interpolationQuality = .none
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: rowCount))
        return ReferenceImageTile(originY: startRow, width: width, height: rowCount, rgba16: samples)
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
