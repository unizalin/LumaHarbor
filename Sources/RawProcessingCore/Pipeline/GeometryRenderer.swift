@preconcurrency import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import Foundation

/// Applies `GeometryAdjustments` to an already-decoded image (design spec
/// §6.5, roadmap Phase 2 "Task 2.2: Geometry render pipeline").
///
/// Documented transform order (roadmap):
///   1. orientation normalize -- already done before this runs: the decoder
///      (`CoreImageRawDecoder`) rotates `CIRAWFilter.outputImage` to display
///      orientation itself (see `ExportMetadataBuilder`'s P1-fix doc comment
///      for the corroborating finding), so this type never reads EXIF
///      orientation.
///   2. crop, in the source image's own (pre-rotate) normalized coordinates
///   3. rotate 90°/flip, then the fine-angle straighten
///   4. perspective
///   5. resize/export -- the caller's job (`ExportResizing`, `PhotoExporter`)
///
/// Both `CoreImagePreviewRenderer` and `PhotoExporter` call this in the same
/// place in their own pipelines, so the preview a user drags a crop handle
/// against and the full-resolution export are the same code path.
public enum GeometryRenderer {
    public static func apply(_ geometry: GeometryAdjustments, to image: CIImage) -> CIImage {
        guard !geometry.isIdentity else { return image }

        var working = image

        if let crop = geometry.crop, !crop.isFull {
            working = cropped(working, to: crop)
        }

        if geometry.rotationDegrees != 0 || geometry.flipHorizontal || geometry.flipVertical {
            working = rotatedAndFlipped(
                working,
                rotationDegrees: geometry.rotationDegrees,
                flipHorizontal: geometry.flipHorizontal,
                flipVertical: geometry.flipVertical
            )
        }

        if geometry.straightenDegrees != 0 {
            working = straightened(working, degrees: geometry.straightenDegrees)
        }

        if geometry.perspectiveHorizontal != 0 || geometry.perspectiveVertical != 0 {
            working = perspectiveCorrected(
                working,
                horizontal: geometry.perspectiveHorizontal,
                vertical: geometry.perspectiveVertical
            )
        }

        return working
    }

    /// Predicts the pixel dimensions `apply(_:to:)` would produce for a
    /// decode of `nativeSize`, without rendering anything -- `PhotoExporter`
    /// uses this to report an export's final size from a cheap metadata
    /// read alone, without a second full decode. Crop and the 90/270 rotate
    /// swap change dimensions predictably from `nativeSize` alone;
    /// straighten and perspective are clamped back to their input canvas by
    /// `apply(_:to:)` (see `straightened`/`perspectiveCorrected`'s own doc
    /// comments) and never change pixel dimensions, so this formula only
    /// has to account for the first two. Whenever `apply(_:to:)`'s actual
    /// image extent is available (the preview path, via
    /// `ImageRenderService.makeCGImage`'s own `cgImage.width/height`),
    /// prefer that over this prediction.
    public static func appliedPixelSize(of nativeSize: CGSize, geometry: GeometryAdjustments) -> CGSize {
        guard nativeSize.width > 0, nativeSize.height > 0 else { return nativeSize }
        var size = nativeSize
        if let crop = geometry.crop, !crop.isFull {
            size = CGSize(
                width: (nativeSize.width * crop.width).rounded(),
                height: (nativeSize.height * crop.height).rounded()
            )
        }
        if geometry.rotationDegrees == 90 || geometry.rotationDegrees == 270 {
            size = CGSize(width: size.height, height: size.width)
        }
        return size
    }

    // MARK: - Crop

    /// `NormalizedCropRect`'s origin is top-left, `[0,1]` per axis (matching
    /// how a UI overlay is normally described); Core Image's own coordinate
    /// system has its origin at the bottom-left with y increasing upward, so
    /// the y axis is flipped converting from one to the other.
    private static func cropped(_ image: CIImage, to crop: NormalizedCropRect) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let pixelWidth = (crop.width * extent.width).rounded()
        let pixelHeight = (crop.height * extent.height).rounded()
        let pixelX = (extent.minX + crop.x * extent.width).rounded()
        let pixelY = (extent.minY + (1 - crop.y - crop.height) * extent.height).rounded()
        return image.cropped(to: CGRect(x: pixelX, y: pixelY, width: pixelWidth, height: pixelHeight))
    }

    // MARK: - Rotate 90 / flip

    private static func rotatedAndFlipped(
        _ image: CIImage,
        rotationDegrees: Double,
        flipHorizontal: Bool,
        flipVertical: Bool
    ) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let center = CGPoint(x: extent.midX, y: extent.midY)

        var transform = CGAffineTransform.identity
        if flipHorizontal { transform = transform.concatenating(CGAffineTransform(scaleX: -1, y: 1)) }
        if flipVertical { transform = transform.concatenating(CGAffineTransform(scaleX: 1, y: -1)) }
        transform = transform.concatenating(CGAffineTransform(rotationAngle: Self.clockwiseRadians(rotationDegrees)))

        return image.transformed(by: aroundCenter(transform, center: center))
    }

    // MARK: - Straighten

    /// Rotates by the fine-angle slider around the working canvas's own
    /// centre, then clips back to that pre-rotation canvas rather than
    /// letting the extent grow to the rotated bounding box. This
    /// deliberately does not auto-crop the transparent corners a non-zero
    /// angle reveals -- pairing a manual crop with a straighten adjustment
    /// is the expected workflow (Task 2.3's UI), and growing the canvas here
    /// would make `appliedPixelSize(of:geometry:)` unable to predict the
    /// output size from metadata alone.
    private static func straightened(_ image: CIImage, degrees: Double) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let center = CGPoint(x: extent.midX, y: extent.midY)
        let transform = aroundCenter(CGAffineTransform(rotationAngle: Self.clockwiseRadians(degrees)), center: center)
        return image.transformed(by: transform).cropped(to: extent)
    }

    // MARK: - Perspective

    /// A first-pass horizontal/vertical keystone correction: moves each
    /// pair of opposite canvas edges toward or away from centre in
    /// proportion to the ±100 slider, via `CIPerspectiveTransform`. Clipped
    /// back to the pre-transform canvas for the same reason `straightened`
    /// is: a predictable, metadata-predictable output size, with corners
    /// left for a manual crop.
    private static func perspectiveCorrected(_ image: CIImage, horizontal: Double, vertical: Double) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }

        // ±100 maps to ±25% of the shorter dimension: strong enough to be
        // visually useful, short of letting opposite corners cross.
        let maxInset = min(extent.width, extent.height) * 0.25
        let hInset = CGFloat(horizontal / 100) * maxInset
        let vInset = CGFloat(vertical / 100) * maxInset

        // Positive `horizontal` narrows the top edge inward (corrects
        // verticals that converge because the camera was tilted up);
        // positive `vertical` narrows the right edge inward.
        let filter = CIFilter.perspectiveTransform()
        filter.inputImage = image
        filter.topLeft = CGPoint(x: extent.minX + hInset, y: extent.maxY - vInset)
        filter.topRight = CGPoint(x: extent.maxX - hInset, y: extent.maxY + vInset)
        filter.bottomRight = CGPoint(x: extent.maxX + hInset, y: extent.minY - vInset)
        filter.bottomLeft = CGPoint(x: extent.minX - hInset, y: extent.minY + vInset)
        guard let output = filter.outputImage else { return image }
        return output.cropped(to: extent)
    }

    // MARK: - Shared

    private static func aroundCenter(_ transform: CGAffineTransform, center: CGPoint) -> CGAffineTransform {
        let toOrigin = CGAffineTransform(translationX: -center.x, y: -center.y)
        let backToCenter = CGAffineTransform(translationX: center.x, y: center.y)
        return toOrigin.concatenating(transform).concatenating(backToCenter)
    }

    /// `CGAffineTransform(rotationAngle:)`'s positive angle turns
    /// counterclockwise in Core Image's own y-up coordinate space (the
    /// standard mathematical convention for a y-up plane); this codebase's
    /// `rotationDegrees`/`straightenDegrees` are documented as a *clockwise*
    /// angle (`GeometryAdjustments.rotatedClockwise()`), matching every
    /// photo editor's "rotate right" convention, so the sign is flipped
    /// here -- pinned by `GeometryRendererTests
    /// .testRotateClockwise90MovesTheTopLeftMarkerToTheTopRight`.
    private static func clockwiseRadians(_ degrees: Double) -> CGFloat {
        CGFloat(-degrees * .pi / 180)
    }
}
