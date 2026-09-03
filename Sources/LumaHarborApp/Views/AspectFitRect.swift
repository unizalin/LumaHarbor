import CoreGraphics

/// Where an `Image` with `.resizable().aspectRatio(contentMode: .fit)`
/// actually lands inside its container, once a symmetric padding is
/// subtracted first -- exactly what `EditorView.previewArea` builds
/// (`.padding(16)`), reproduced here as a pure function so `CropOverlayView`
/// can draw and hit-test against the same rectangle the photo itself
/// occupies, in SwiftUI's own top-left-origin, y-down coordinate space
/// (matching `NormalizedCropRect`'s own convention -- no axis flip needed
/// here; that only happens once inside `GeometryRenderer`, converting into
/// Core Image's y-up native space).
public enum AspectFitRect {
    public static func fitting(imageSize: CGSize, in container: CGSize, padding: CGFloat = 0) -> CGRect {
        let available = CGSize(
            width: max(container.width - padding * 2, 0),
            height: max(container.height - padding * 2, 0)
        )
        guard imageSize.width > 0, imageSize.height > 0, available.width > 0, available.height > 0 else {
            return CGRect(origin: CGPoint(x: padding, y: padding), size: available)
        }

        let imageAspect = imageSize.width / imageSize.height
        let availableAspect = available.width / available.height
        let fittedSize: CGSize
        if imageAspect > availableAspect {
            // The image is relatively wider than the available box: its full
            // width fits, so width is the constraining dimension.
            fittedSize = CGSize(width: available.width, height: available.width / imageAspect)
        } else {
            fittedSize = CGSize(width: available.height * imageAspect, height: available.height)
        }

        let originX = padding + (available.width - fittedSize.width) / 2
        let originY = padding + (available.height - fittedSize.height) / 2
        return CGRect(origin: CGPoint(x: originX, y: originY), size: fittedSize)
    }

    /// The inverse of `fitting(imageSize:in:padding:)`: given a point in the
    /// same view space `fitting` was computed against (a click location,
    /// say) and that fitted rectangle, returns the corresponding pixel
    /// coordinate in `imageSize`'s own top-left-origin space -- what
    /// `PixelSampler.sample(at:in:)` expects. Clamped into the image's own
    /// bounds, so a click a point or two outside the fitted rect (a normal
    /// rounding case right at the edge) still resolves to the nearest real
    /// pixel instead of an out-of-bounds coordinate.
    public static func imagePixel(at point: CGPoint, imageFrame: CGRect, imageSize: CGSize) -> CGPoint {
        guard imageFrame.width > 0, imageFrame.height > 0 else { return .zero }
        let fractionX = (point.x - imageFrame.minX) / imageFrame.width
        let fractionY = (point.y - imageFrame.minY) / imageFrame.height
        let clampedFractionX = min(max(fractionX, 0), 1)
        let clampedFractionY = min(max(fractionY, 0), 1)
        return CGPoint(x: clampedFractionX * imageSize.width, y: clampedFractionY * imageSize.height)
    }
}
