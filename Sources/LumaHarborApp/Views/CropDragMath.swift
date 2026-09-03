import CoreGraphics
import RawProcessingCore

/// The pure geometry `CropOverlayView`'s drag gestures reduce to: given the
/// crop rect at the moment a drag *began* and how far the pointer has moved
/// since, produce the crop rect *now*. Kept separate from the view itself so
/// the direction/clamping math is unit-testable without driving a real
/// `DragGesture` (this package has no SwiftUI view-interaction test
/// dependency -- see `AdjustmentGroupPanelsContractTests`'s own header
/// comment).
public enum CropHandle: Equatable, Sendable {
    /// Resizes from one corner; the opposite corner stays fixed.
    case topLeft, topRight, bottomLeft, bottomRight
    /// Translates the whole rect without resizing it.
    case move
}

public enum CropDragMath {
    /// `translation` is in the same screen-point units as `imageFrameSize`
    /// (the fitted image rect's own width/height, from `AspectFitRect`) --
    /// both in SwiftUI's top-left-origin, y-down space, which is exactly
    /// `NormalizedCropRect`'s own convention, so no axis flip is needed here.
    public static func updatedCrop(
        base: NormalizedCropRect,
        handle: CropHandle,
        translation: CGSize,
        imageFrameSize: CGSize
    ) -> NormalizedCropRect {
        guard imageFrameSize.width > 0, imageFrameSize.height > 0 else { return base }
        let dx = Double(translation.width / imageFrameSize.width)
        let dy = Double(translation.height / imageFrameSize.height)

        switch handle {
        case .move:
            return NormalizedCropRect(x: base.x + dx, y: base.y + dy, width: base.width, height: base.height)
        case .topLeft:
            return NormalizedCropRect(x: base.x + dx, y: base.y + dy, width: base.width - dx, height: base.height - dy)
        case .topRight:
            return NormalizedCropRect(x: base.x, y: base.y + dy, width: base.width + dx, height: base.height - dy)
        case .bottomLeft:
            return NormalizedCropRect(x: base.x + dx, y: base.y, width: base.width - dx, height: base.height + dy)
        case .bottomRight:
            return NormalizedCropRect(x: base.x, y: base.y, width: base.width + dx, height: base.height + dy)
        }
    }
}
