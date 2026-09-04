import CoreGraphics
import RawProcessingCore

/// The pure geometry `SpotHealOverlayView`'s three drag gestures (move
/// target, move source, resize) reduce to -- matching
/// `LinearGradientDragMath`'s own established split for exactly the same
/// reason: the position/size math is unit-testable without driving a real
/// `DragGesture`.
public enum SpotHealDragMath {
    /// The target handle: moves `x`/`y` only, leaving everything else
    /// untouched. Same convention as `LinearGradientDragMath
    /// .updatedPosition` -- SwiftUI's top-left-origin, y-down space is
    /// exactly `LocalAdjustmentGeometry.x`/`.y`'s own convention, so no axis
    /// flip is needed here.
    public static func updatedTargetPosition(
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

    /// The source handle (clone mode only): moves `sourceX`/`sourceY` only.
    /// `base` must already have a concrete `sourceX`/`sourceY` -- there is
    /// no such thing as dragging from "nowhere". A caller whose model still
    /// has `nil` (clone mode, no point placed yet) must first resolve a
    /// starting point via `resolvedSource(for:)` and fold it into the
    /// `base` it passes here (matching where the handle is actually drawn),
    /// exactly as `LinearGradientOverlayView`'s own drag gestures capture a
    /// stable base once per gesture.
    public static func updatedSourcePosition(
        base: LocalAdjustmentGeometry,
        translation: CGSize,
        imageFrameSize: CGSize
    ) -> LocalAdjustmentGeometry {
        guard imageFrameSize.width > 0, imageFrameSize.height > 0 else { return base }
        let resolved = resolvedSource(for: base)
        var result = base
        result.sourceX = resolved.x + Double(translation.width / imageFrameSize.width)
        result.sourceY = resolved.y + Double(translation.height / imageFrameSize.height)
        return result
    }

    /// The size handle: sets `radius` from the straight-line distance
    /// between the target and the handle's current position, normalized to
    /// the *shorter* side of the fitted image frame -- matching
    /// `LocalAdjustmentRenderer.applySpotHeal`'s own
    /// `min(extent.width, extent.height)` pixel conversion exactly, so the
    /// handle's on-screen circle always matches the actual render radius
    /// rather than an approximation of it (unlike the linear gradient's
    /// `range`, which normalizes to half the frame's *diagonal* because
    /// that is what `linearGradientMask` itself uses).
    public static func updatedRadius(
        base: LocalAdjustmentGeometry,
        targetToHandleTranslation: CGVector,
        imageFrameSize: CGSize
    ) -> LocalAdjustmentGeometry {
        let shorterSide = min(imageFrameSize.width, imageFrameSize.height)
        guard shorterSide > 0 else { return base }
        let distance = (targetToHandleTranslation.dx * targetToHandleTranslation.dx
            + targetToHandleTranslation.dy * targetToHandleTranslation.dy).squareRoot()
        var result = base
        result.radius = Double(distance / shorterSide)
        return result
    }

    /// Which point a spot heal entry's source handle should be drawn at and
    /// dragged from, even before the user has placed an explicit one.
    /// Deliberately the *same* fixed-offset formula as
    /// `LocalAdjustmentRenderer.autoSourcePoint(for:extent:)` (duplicated,
    /// not shared -- `LumaHarborApp` cannot reach into that private
    /// render-layer function, and there is no third module both could
    /// depend on without inverting the render pipeline's own layering) --
    /// pinned identical by `SpotHealDragMathTests` so the overlay's initial
    /// handle position, before any drag happens, always matches what
    /// `.heal` mode (or unplaced `.clone`) actually renders. A source point
    /// only counts as "placed" when *both* coordinates are set -- a
    /// partially-set pair (which the schema layer never itself produces,
    /// but a hand-edited sidecar could) is treated the same as neither
    /// being set.
    public static func resolvedSource(for geometry: LocalAdjustmentGeometry) -> (x: Double, y: Double) {
        if let sourceX = geometry.sourceX, let sourceY = geometry.sourceY {
            return (sourceX, sourceY)
        }
        let offsetNormalized = min(geometry.radius * 2.5, 0.45)
        let above = geometry.y - offsetNormalized
        let normalizedY = above >= 0 ? above : min(geometry.y + offsetNormalized, 1)
        return (geometry.x, normalizedY)
    }
}
