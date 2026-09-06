import CoreGraphics
import CoreImage
import CoreText
import Foundation

/// Draws `Watermark.text` onto an export's rendered pixels (design spec
/// §6.11; roadmap Phase 5 Task 5.2). Pure `CIImage -> CIImage`, like every
/// other renderer in this module (`GeometryRenderer`, `LocalAdjustmentRenderer`)
/// -- no decoder, no file I/O, so it's testable with a synthetic fixture.
///
/// Built on CoreText + CoreGraphics rather than AppKit's `NSAttributedString
/// .draw(in:)`, so this stays available if `RawProcessingCore` is ever
/// linked into an iPadOS target (spec: macOS ships first, but the core
/// modules must not block iPadOS reuse).
public enum WatermarkRenderer {
    /// Returns `image` byte-for-byte unchanged when `watermark` is `nil` or
    /// its text is empty/whitespace-only -- the common "no watermark"
    /// case must never pay for a render pass or risk a no-op filter
    /// changing pixel values by a rounding hair.
    public static func apply(_ watermark: Watermark?, to image: CIImage) -> CIImage {
        guard let watermark, !watermark.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return image
        }
        let canvasSize = image.extent.size
        guard canvasSize.width > 0, canvasSize.height > 0,
              let textImage = renderText(watermark.text, canvasSize: canvasSize, sizeFraction: watermark.sizeFraction) else {
            return image
        }

        let positioned = position(textImage, canvasSize: canvasSize, at: watermark.position)
        let faded = positioned.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: watermark.opacity)
        ])
        return faded.composited(over: image)
    }

    /// Renders `text` in white onto a tightly-cropped transparent bitmap,
    /// sized off `canvasSize`'s shorter edge so the same `sizeFraction`
    /// reads the same relative size on a portrait or landscape export.
    private static func renderText(_ text: String, canvasSize: CGSize, sizeFraction: Double) -> CIImage? {
        let fontSize = max(8, min(canvasSize.width, canvasSize.height) * CGFloat(sizeFraction))
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        ]
        let line = CTLineCreateWithAttributedString(
            CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)
        )
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let padding = fontSize * 0.3
        let width = max(1, Int(ceil(bounds.width + padding * 2)))
        let height = max(1, Int(ceil(bounds.height + padding * 2)))

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.setTextDrawingMode(.fill)
        context.textPosition = CGPoint(x: padding - bounds.minX, y: padding - bounds.minY)
        CTLineDraw(line, context)

        guard let cgImage = context.makeImage() else { return nil }
        return CIImage(cgImage: cgImage)
    }

    /// Translates the rendered text image so it sits in `position`'s named
    /// corner (or the centre), inset by a small margin proportional to the
    /// canvas so it never touches the very edge of the frame.
    private static func position(_ textImage: CIImage, canvasSize: CGSize, at position: Watermark.Position) -> CIImage {
        let margin = min(canvasSize.width, canvasSize.height) * 0.03
        let textExtent = textImage.extent
        let origin: CGPoint
        switch position {
        case .topLeft:
            origin = CGPoint(x: margin, y: canvasSize.height - textExtent.height - margin)
        case .topRight:
            origin = CGPoint(x: canvasSize.width - textExtent.width - margin, y: canvasSize.height - textExtent.height - margin)
        case .bottomLeft:
            origin = CGPoint(x: margin, y: margin)
        case .bottomRight:
            origin = CGPoint(x: canvasSize.width - textExtent.width - margin, y: margin)
        case .center:
            origin = CGPoint(x: (canvasSize.width - textExtent.width) / 2, y: (canvasSize.height - textExtent.height) / 2)
        }
        let translation = CGAffineTransform(translationX: origin.x - textExtent.minX, y: origin.y - textExtent.minY)
        return textImage.transformed(by: translation)
    }
}
