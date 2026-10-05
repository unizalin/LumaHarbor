@preconcurrency import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import Foundation

/// Renders the independent source-coordinate brush-mask pipeline. Masks are
/// composited in array order and each mask's local adjustment is evaluated once
/// against the image produced by the preceding mask.
public enum BrushMaskRenderer {
    public static func apply(
        _ masks: [BrushMask],
        to image: CIImage,
        mapping: BrushCoordinateMapping? = nil,
        recipe: ResolvedRawRenderRecipe? = nil,
        scaleFactor: Double = 1
    ) -> CIImage {
        (try? applyValidated(masks, to: image, mapping: mapping, recipe: recipe, scaleFactor: scaleFactor)) ?? image
    }

    /// Strict variant used by preview/export. Invalid brush data or a point
    /// outside the current geometry is rejected before any pixels are written.
    public static func applyValidated(
        _ masks: [BrushMask],
        to image: CIImage,
        mapping: BrushCoordinateMapping? = nil,
        recipe: ResolvedRawRenderRecipe? = nil,
        scaleFactor: Double = 1
    ) throws -> CIImage {
        guard !masks.isEmpty, image.extent.width > 0, image.extent.height > 0 else { return image }
        var working = image
        let coordinateMapping: BrushCoordinateMapping
        if let mapping {
            coordinateMapping = mapping
        } else {
            guard let created = try? BrushCoordinateMapping(sourceExtent: image.extent, geometry: .neutral) else { return image }
            coordinateMapping = created
        }
        for mask in masks {
            _ = try mask.validated()
            for stroke in mask.strokes where !stroke.points.isEmpty {
                for point in stroke.points { _ = try coordinateMapping.sourceToDisplay(point) }
            }
        }
        for mask in masks where mask.isEnabled {
            guard mask.rendererVersion == BrushMask.currentRendererVersion,
                  !mask.adjustments.isNeutral else { continue }
            let coverage = try renderCoverage(mask, imageExtent: image.extent, mapping: coordinateMapping)
            let parameters = parameters(for: mask.adjustments)
            // A brush patch is local: global recipe/profile/lens stages have
            // already run immediately before this stage and must not execute a
            // second time for each mask.
            let adjusted = AdjustmentPipeline().apply(parameters, to: working, recipe: nil, scaleFactor: scaleFactor)
            let maskToAlpha = CIFilter.maskToAlpha()
            maskToAlpha.inputImage = coverage
            let normalizedCoverage = maskToAlpha.outputImage?.cropped(to: working.extent) ?? coverage
            let blend = CIFilter.blendWithAlphaMask()
            blend.inputImage = adjusted.cropped(to: working.extent)
            blend.backgroundImage = working
            blend.maskImage = normalizedCoverage
            working = blend.outputImage?.cropped(to: working.extent) ?? working
        }
        return working
    }

    public static func render(
        _ masks: [BrushMask],
        to image: CIImage,
        mapping: BrushCoordinateMapping? = nil,
        recipe: ResolvedRawRenderRecipe? = nil,
        scaleFactor: Double = 1
    ) -> CIImage {
        apply(masks, to: image, mapping: mapping, recipe: recipe, scaleFactor: scaleFactor)
    }

    public static func render(masks: [BrushMask], to image: CIImage, mapping: BrushCoordinateMapping? = nil) -> CIImage {
        apply(masks, to: image, mapping: mapping)
    }

    private static func parameters(for patch: BrushMaskPatch) -> PhotoAdjustments {
        var adjustments = PhotoAdjustments.neutral
        if let value = patch.exposure { adjustments.exposure = value }
        if let value = patch.contrast { adjustments.contrast = value }
        if let value = patch.highlights { adjustments.highlights = value }
        if let value = patch.shadows { adjustments.shadows = value }
        if let value = patch.whites { adjustments.whites = value }
        if let value = patch.blacks { adjustments.blacks = value }
        if let value = patch.saturation { adjustments.saturation = value }
        if let value = patch.temperature { adjustments.temperature = value }
        if let value = patch.tint { adjustments.tint = value }
        return adjustments
    }

    private static func renderCoverage(
        _ mask: BrushMask,
        imageExtent: CGRect,
        mapping: BrushCoordinateMapping
    ) throws -> CIImage {
        var coverage = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: imageExtent)
        for stroke in mask.strokes {
            let points = try stroke.validated().points
            guard !points.isEmpty, stroke.flow > 0 else { continue }
            let samples = try sample(points: points, stroke: stroke, mapping: mapping)
            var strokeCoverage = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: imageExtent)
            for point in samples {
                let stamp = stamp(at: point, stroke: stroke, extent: imageExtent)
                let composite = CIFilter.sourceOverCompositing()
                composite.inputImage = stamp
                composite.backgroundImage = strokeCoverage
                strokeCoverage = composite.outputImage?.cropped(to: imageExtent) ?? strokeCoverage
            }
            if stroke.mode == .paint {
                let composite = CIFilter.sourceOverCompositing()
                composite.inputImage = strokeCoverage
                composite.backgroundImage = coverage
                coverage = composite.outputImage?.cropped(to: imageExtent) ?? coverage
            } else {
                let inverse = CIFilter.colorMatrix()
                inverse.inputImage = strokeCoverage
                inverse.rVector = CIVector(x: -1, y: 0, z: 0, w: 0)
                inverse.gVector = CIVector(x: 0, y: -1, z: 0, w: 0)
                inverse.bVector = CIVector(x: 0, y: 0, z: -1, w: 0)
                inverse.aVector = CIVector(x: 0, y: 0, z: 0, w: -1)
                inverse.biasVector = CIVector(x: 1, y: 1, z: 1, w: 1)
                let minimum = CIFilter.minimumCompositing()
                minimum.inputImage = inverse.outputImage?.cropped(to: imageExtent)
                minimum.backgroundImage = coverage
                coverage = minimum.outputImage?.cropped(to: imageExtent) ?? coverage
            }
        }
        return coverage
    }

    private static func sample(
        points: [BrushMaskPoint],
        stroke: BrushMaskStroke,
        mapping: BrushCoordinateMapping
    ) throws -> [CGPoint] {
        guard let first = points.first else { return [] }
        let firstPoint = try mapping.sourceToSourcePixel(first)
        var output = [firstPoint]
        let spacing = max(stroke.size / 8, 1 / min(mapping.sourceExtent.width, mapping.sourceExtent.height))
        var remaining = 0.0
        var previous = firstPoint
        for point in points.dropFirst() {
            let current = try mapping.sourceToSourcePixel(point)
            let dx = Double(current.x - previous.x), dy = Double(current.y - previous.y)
            let segment = (dx * dx + dy * dy).squareRoot() / Double(min(mapping.displayExtent.width, mapping.displayExtent.height))
            guard segment.isFinite, segment > 0 else { continue }
            var travelled = remaining
            while travelled <= segment + 1e-12 {
                let t = travelled / segment
                output.append(CGPoint(x: previous.x + CGFloat(t) * (current.x - previous.x),
                                      y: previous.y + CGFloat(t) * (current.y - previous.y)))
                travelled += spacing
            }
            remaining = travelled - segment
            previous = current
        }
        if output.last != previous { output.append(previous) }
        return output
    }

    private static func stamp(at point: CGPoint, stroke: BrushMaskStroke, extent: CGRect) -> CIImage {
        let shortSide = min(extent.width, extent.height)
        let radius = max(CGFloat(stroke.size) * shortSide / 2, 0.5)
        // Brush points are persisted/displayed in top-left visual coordinates;
        // Core Image's extent uses a bottom-left origin.
        let center = CGPoint(x: point.x, y: extent.maxY - (point.y - extent.minY))
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        var stamp = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: CGFloat(stroke.flow))).cropped(to: rect)
        if stroke.feather > 0 {
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = stamp
            blur.radius = Float(max(radius * CGFloat(stroke.feather), 0.25))
            stamp = blur.outputImage?.cropped(to: extent) ?? stamp
        }
        return stamp.cropped(to: extent)
    }
}
