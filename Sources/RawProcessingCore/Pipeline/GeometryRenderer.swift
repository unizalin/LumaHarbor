@preconcurrency import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import Foundation

/// Applies `GeometryAdjustments` to an already-decoded image (design spec
/// §6.5, roadmap Phase 2 "Task 2.2: Geometry render pipeline").
///
/// Whole-pipeline transform order (both `CoreImagePreviewRenderer` and
/// `PhotoExporter`, in that same order):
///   1. orientation normalize -- already done before this runs: the decoder
///      (`CoreImageRawDecoder`) rotates `CIRAWFilter.outputImage` to display
///      orientation itself (see `ExportMetadataBuilder`'s P1-fix doc comment
///      for the corroborating finding), so this type never reads EXIF
///      orientation.
///   2. `AdjustmentPipeline` -- basic/tone/colour adjustments, in linear
///      light, before this type ever runs.
///   3. rotate 90°/flip, then the fine-angle straighten (this type)
///   4. perspective (this type)
///   5. crop, in that already-rotated/flipped/straightened frame's own
///      normalized coordinates (this type)
///   6. `LocalAdjustmentRenderer` -- linear gradient / spot heal (Phase 4
///      Task 4.2/4.4), *after* this type, not before: a local adjustment's
///      anchor point is placed by the user dragging on the displayed
///      preview, which is always the fully rotated/cropped/straightened
///      image, never the pre-geometry source -- the same reasoning that
///      already put crop last within this type (see the independent-review
///      P1 fix note below).
///   7. resize/export -- the caller's job (`ExportResizing`, `PhotoExporter`)
///
/// Independent-review P1 fix, corrected from the roadmap's own originally
/// *suggested* order (crop before rotate, in the un-rotated source's
/// coordinates): `EditorSession.displayedImage` -- what `CropOverlayView`
/// (Task 2.3) actually shows and drags a crop rect against -- is always the
/// fully rotated/flipped/straightened preview, never the pre-rotation
/// source. Cropping in un-rotated coordinates meant a crop rect the user
/// drew on the rotated preview did not correspond to the crop that actually
/// got applied whenever any rotation/flip was already active, and re-editing
/// an *existing* crop was worse still: the displayed preview already showed
/// the cropped-and-filled result, so the overlay had no correct frame to
/// reference at all. Putting crop last means it always operates in exactly
/// the coordinate space the user is looking at, matching how virtually
/// every other photo editor's crop tool behaves, and `EditorSession
/// .displayedAdjustments` strips `geometry.crop` while `toolMode == .crop`
/// so the crop tool's own preview shows the correct pre-crop (but
/// post-rotate) reference frame, for both a first crop and an edit to one
/// already committed.
///
/// Both `CoreImagePreviewRenderer` and `PhotoExporter` call this in the same
/// place in their own pipelines, so the preview a user drags a crop handle
/// against and the full-resolution export are the same code path.
public enum GeometryRenderer {
    public static func apply(_ geometry: GeometryAdjustments, to image: CIImage) -> CIImage {
        guard !geometry.isIdentity else { return image }

        var working = image

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

        if let pins = geometry.cornerPins, !pins.isIdentity {
            working = cornerPinsCorrected(working, pins: pins)
        }

        if let crop = geometry.crop, !crop.isFull {
            working = cropped(working, to: crop)
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
        if geometry.rotationDegrees == 90 || geometry.rotationDegrees == 270 {
            size = CGSize(width: size.height, height: size.width)
        }
        if let crop = geometry.crop, !crop.isFull {
            size = CGSize(
                width: (size.width * crop.width).rounded(),
                height: (size.height * crop.height).rounded()
            )
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

    private static func cornerPinsCorrected(_ image: CIImage, pins: PerspectiveCornerPins) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: imagePoint(for: pins.topLeft, extent: extent)), forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: imagePoint(for: pins.topRight, extent: extent)), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: imagePoint(for: pins.bottomRight, extent: extent)), forKey: "inputBottomRight")
        filter.setValue(CIVector(cgPoint: imagePoint(for: pins.bottomLeft, extent: extent)), forKey: "inputBottomLeft")

        guard let output = filter.outputImage, output.extent.width > 0, output.extent.height > 0 else { return image }
        let scaleX = extent.width / output.extent.width
        let scaleY = extent.height / output.extent.height
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        return scaled.cropped(to: extent)
    }

    private static func imagePoint(for point: NormalizedPoint, extent: CGRect) -> CGPoint {
        CGPoint(
            x: extent.minX + CGFloat(point.x) * extent.width,
            y: extent.minY + CGFloat(1.0 - point.y) * extent.height
        )
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
