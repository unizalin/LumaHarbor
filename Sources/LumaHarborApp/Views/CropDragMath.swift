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
        imageFrameSize: CGSize,
        normalizedAspectRatio: Double? = nil
    ) -> NormalizedCropRect {
        guard imageFrameSize.width > 0, imageFrameSize.height > 0 else { return base }
        let dx = Double(translation.width / imageFrameSize.width)
        let dy = Double(translation.height / imageFrameSize.height)

        if let normalizedAspectRatio, normalizedAspectRatio.isFinite, normalizedAspectRatio > 0,
           handle != .move {
            return aspectLockedCrop(
                base: base,
                handle: handle,
                dx: dx,
                dy: dy,
                ratio: normalizedAspectRatio
            )
        }

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

    private static func aspectLockedCrop(
        base: NormalizedCropRect,
        handle: CropHandle,
        dx: Double,
        dy: Double,
        ratio: Double
    ) -> NormalizedCropRect {
        let movesLeft = handle == .topLeft || handle == .bottomLeft
        let movesTop = handle == .topLeft || handle == .topRight
        let fixedX = movesLeft ? base.x + base.width : base.x
        let fixedY = movesTop ? base.y + base.height : base.y
        let draggedX = movesLeft ? base.x + dx : base.x + base.width + dx
        let draggedY = movesTop ? base.y + dy : base.y + base.height + dy

        let pointerWidth = max(abs(draggedX - fixedX), NormalizedCropRect.minimumDimension)
        let pointerHeight = max(abs(draggedY - fixedY), NormalizedCropRect.minimumDimension)
        let widthFromHeight = pointerHeight * ratio

        // Let the axis with the larger requested change drive the lock. This
        // keeps a mostly-horizontal or mostly-vertical drag responsive while
        // making the other dimension follow the selected ratio.
        let width: Double
        if abs(pointerWidth - base.width) >= abs(widthFromHeight - base.width) {
            width = pointerWidth
        } else {
            width = widthFromHeight
        }

        let maxWidth = movesLeft ? fixedX : 1 - fixedX
        let maxHeight = movesTop ? fixedY : 1 - fixedY
        let maxWidthForRatio = min(maxWidth, maxHeight * ratio)
        let minWidthForRatio = max(NormalizedCropRect.minimumDimension, NormalizedCropRect.minimumDimension * ratio)
        guard maxWidthForRatio >= minWidthForRatio else {
            return NormalizedCropRect(
                x: movesLeft ? fixedX - maxWidthForRatio : fixedX,
                y: movesTop ? fixedY - maxWidthForRatio / ratio : fixedY,
                width: maxWidthForRatio,
                height: maxWidthForRatio / ratio
            )
        }

        let clampedWidth = min(max(width, minWidthForRatio), maxWidthForRatio)
        let clampedHeight = clampedWidth / ratio
        return NormalizedCropRect(
            x: movesLeft ? fixedX - clampedWidth : fixedX,
            y: movesTop ? fixedY - clampedHeight : fixedY,
            width: clampedWidth,
            height: clampedHeight
        )
    }
}
