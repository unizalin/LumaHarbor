import CoreGraphics
import RawProcessingCore

/// The pure geometry `LinearGradientOverlayView`'s two drag gestures reduce
/// to -- given the gradient's geometry at the moment a drag *began*, how far
/// the pointer has moved since, and the fitted image frame's own size,
/// produce the geometry *now*. Kept separate from the view itself so the
/// direction/range math is unit-testable without driving a real
/// `DragGesture`, matching `CropDragMath`'s own established split for
/// exactly the same reason.
public enum LinearGradientDragMath {
    /// The center handle: moves `x`/`y` only, leaving angle/range/feather
    /// untouched. `translation` is in the same screen-point units as
    /// `imageFrameSize` (the fitted image rect's own width/height), both in
    /// SwiftUI's top-left-origin, y-down space -- exactly
    /// `LocalAdjustmentGeometry.x`/`.y`'s own convention, so no axis flip is
    /// needed here (unlike `LocalAdjustmentRenderer`, which operates in
    /// Core Image's y-up space).
    public static func updatedPosition(
        base: LocalAdjustmentGeometry,
        translation: CGSize,
        imageFrameSize: CGSize
    ) -> LocalAdjustmentGeometry {
        guard imageFrameSize.width > 0, imageFrameSize.height > 0 else { return base }
        var result = base
        result.x = base.x + Double(translation.width / imageFrameSize.width)
        result.y = base.y + Double(translation.height / imageFrameSize.height)
        return result
    }

    /// The direction handle: dragging its tip sets `angleDegrees` (the
    /// vector from the anchor to the new tip position) and `range` (the
    /// tip's distance from the anchor, normalized the same way
    /// `LocalAdjustmentRenderer.linearGradientMask(_:extent:)` computes its
    /// own `halfLength`, so the handle's on-screen position always matches
    /// what will actually render) together, leaving `x`/`y`/`feather`
    /// untouched. A drag whose resulting length is at or below `minimumDragPoints`
    /// leaves the angle alone -- indistinguishable from "the user hasn't
    /// really moved the handle yet", and `atan2(0, 0)` would otherwise
    /// snap it to an arbitrary 0.
    public static func updatedDirection(
        base: LocalAdjustmentGeometry,
        anchorToTipTranslation: CGVector,
        imageFrameSize: CGSize,
        minimumDragPoints: CGFloat = 1
    ) -> LocalAdjustmentGeometry {
        let diagonal = (imageFrameSize.width * imageFrameSize.width + imageFrameSize.height * imageFrameSize.height).squareRoot()
        guard diagonal > 0 else { return base }

        let distance = (anchorToTipTranslation.dx * anchorToTipTranslation.dx + anchorToTipTranslation.dy * anchorToTipTranslation.dy).squareRoot()
        var result = base
        if distance > minimumDragPoints {
            result.angleDegrees = Double(atan2(anchorToTipTranslation.dy, anchorToTipTranslation.dx) * 180 / .pi)
        }
        result.range = Double(distance / (diagonal / 2))
        return result
    }
}
