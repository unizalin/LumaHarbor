import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ReferenceImageBufferError: Error, Equatable, Hashable, Sendable {
    case invalidSource
    case unsupportedFormat
    case missingColorSpace
    case unsupportedColorSpace
    case invalidBitDepth(Int)
    case invalidDimensions
    case decodeFailed
    case invalidSample
}

/// A decoded, encoded-sRGB reference image suitable for deterministic pixel
/// comparisons. The buffer deliberately keeps at least 16 bits per component
/// until the caller chooses a comparison representation.
public struct ReferenceImageBuffer: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let bitsPerComponent: Int
    public let colorSpaceIdentifier: String
    public let hasAlpha: Bool
    public let pixels: [SIMD4<Float>]

    public static func load(from url: URL) throws -> ReferenceImageBuffer {
        guard url.isFileURL else {
            throw ReferenceImageBufferError.invalidSource
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ReferenceImageBufferError.invalidSource
        }
        guard let sourceType = CGImageSourceGetType(source),
              UTType(sourceType as String)?.conforms(to: .tiff) == true else {
            throw ReferenceImageBufferError.unsupportedFormat
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let profileName = properties[kCGImagePropertyProfileName] as? String else {
            throw ReferenceImageBufferError.missingColorSpace
        }
        guard profileName == "sRGB IEC61966-2.1" else {
            throw ReferenceImageBufferError.unsupportedColorSpace
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ReferenceImageBufferError.decodeFailed
        }
        guard image.width > 0, image.height > 0 else {
            throw ReferenceImageBufferError.invalidDimensions
        }
        guard image.bitsPerComponent >= 16 else {
            throw ReferenceImageBufferError.invalidBitDepth(image.bitsPerComponent)
        }
        guard let colorSpace = image.colorSpace else {
            throw ReferenceImageBufferError.missingColorSpace
        }
        guard let colorSpaceName = colorSpace.name as String?,
              colorSpaceName == CGColorSpace.sRGB as String else {
            throw ReferenceImageBufferError.unsupportedColorSpace
        }

        let alphaInfo = image.alphaInfo
        let hasAlpha = Self.alphaInfoHasChannel(alphaInfo)
        let componentCount = 4
        var samples = [UInt16](repeating: 0, count: image.width * image.height * componentCount)
        let bitmapInfo = CGBitmapInfo.byteOrder16Little.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: &samples,
            width: image.width,
            height: image.height,
            bitsPerComponent: 16,
            bytesPerRow: image.width * componentCount * MemoryLayout<UInt16>.size,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw ReferenceImageBufferError.decodeFailed
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        var pixels: [SIMD4<Float>] = []
        pixels.reserveCapacity(image.width * image.height)
        for offset in stride(from: 0, to: samples.count, by: componentCount) {
            let alpha = normalized(samples[offset + 3])
            let red = unpremultiply(normalized(samples[offset]), by: alpha)
            let green = unpremultiply(normalized(samples[offset + 1]), by: alpha)
            let blue = unpremultiply(normalized(samples[offset + 2]), by: alpha)
            let pixel = SIMD4<Float>(red, green, blue, alpha)
            guard pixel.x.isFinite, pixel.y.isFinite, pixel.z.isFinite, pixel.w.isFinite else {
                throw ReferenceImageBufferError.invalidSample
            }
            pixels.append(pixel)
        }

        return ReferenceImageBuffer(
            width: image.width,
            height: image.height,
            bitsPerComponent: image.bitsPerComponent,
            colorSpaceIdentifier: CGColorSpace.sRGB as String,
            hasAlpha: hasAlpha,
            pixels: pixels
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

    private static func normalized(_ raw: UInt16) -> Float {
        // The context writes little-endian components into host-order UInt16
        // storage, so each value can be normalized without a byte swap.
        Float(raw) / Float(UInt16.max)
    }

    private static func unpremultiply(_ value: Float, by alpha: Float) -> Float {
        guard alpha > 0 else { return 0 }
        return min(max(value / alpha, 0), 1)
    }
}
