import CoreGraphics

/// Reads one pixel's colour out of an already-rendered `CGImage`, as
/// gamma-encoded sRGB in `0...1` per channel -- the same representation
/// `ImageRenderService.makeCGImage(_:)` produces. The white balance
/// eyedropper (design spec §6.4) uses this to sample what's actually on
/// screen, not the RAW file's own metadata.
public enum PixelSampler {
    /// `point` is in image-pixel coordinates, top-left origin (matching
    /// `NormalizedCropRect`/`AspectFitRect`'s convention, not Core
    /// Graphics/Core Image's own bottom-left-origin space) -- clamped to the
    /// image's own bounds rather than returning `nil` for an
    /// edge-adjacent point, so a coordinate-mapping rounding error at the
    /// very edge degrades to the nearest real pixel instead of sampling
    /// nothing.
    public static func sample(at point: CGPoint, in image: CGImage) -> (red: Double, green: Double, blue: Double)? {
        guard image.width > 0, image.height > 0 else { return nil }
        let x = min(max(Int(point.x), 0), image.width - 1)
        let y = min(max(Int(point.y), 0), image.height - 1)

        var bytes = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &bytes,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // `CGContext`'s own origin is bottom-left, so the requested row is
        // flipped and the full-size draw offset so the wanted pixel lands
        // on the 1x1 canvas -- the same technique this codebase's own test
        // helpers (e.g. `AdjustmentPipelineTests.pixel(at:in:)`) already use.
        context.draw(image, in: CGRect(
            x: -CGFloat(x),
            y: -(CGFloat(image.height) - 1 - CGFloat(y)),
            width: CGFloat(image.width),
            height: CGFloat(image.height)
        ))
        return (Double(bytes[0]) / 255, Double(bytes[1]) / 255, Double(bytes[2]) / 255)
    }
}
