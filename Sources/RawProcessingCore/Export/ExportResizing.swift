import CoreGraphics
import Foundation

/// Max-width / max-height export resizing (design spec §6.11). Pure
/// geometry with no Core Image dependency, so it's testable with plain
/// `CGSize` values.
public enum ExportResizing {
    /// A uniform-scale transform that fits `nativeSize` within the given
    /// caps while preserving aspect ratio. Identity whenever both caps are
    /// `nil`, non-positive, or already satisfied -- resizing never upscales.
    public static func fittingTransform(
        nativeSize: CGSize,
        maximumWidth: Int?,
        maximumHeight: Int?
    ) -> CGAffineTransform {
        guard nativeSize.width > 0, nativeSize.height > 0 else { return .identity }

        var scale = 1.0
        if let maximumWidth, maximumWidth > 0 {
            scale = min(scale, Double(maximumWidth) / Double(nativeSize.width))
        }
        if let maximumHeight, maximumHeight > 0 {
            scale = min(scale, Double(maximumHeight) / Double(nativeSize.height))
        }
        guard scale < 1 else { return .identity }
        return CGAffineTransform(scaleX: scale, y: scale)
    }

    /// `nativeSize` scaled by `fittingTransform(nativeSize:maximumWidth:
    /// maximumHeight:)`, rounded down to whole pixels so the result never
    /// exceeds the requested caps.
    public static func fittedSize(
        nativeSize: CGSize,
        maximumWidth: Int?,
        maximumHeight: Int?
    ) -> CGSize {
        let transform = fittingTransform(nativeSize: nativeSize, maximumWidth: maximumWidth, maximumHeight: maximumHeight)
        let fitted = nativeSize.applying(transform)
        guard transform != .identity else { return nativeSize }
        return CGSize(width: fitted.width.rounded(.down), height: fitted.height.rounded(.down))
    }
}
