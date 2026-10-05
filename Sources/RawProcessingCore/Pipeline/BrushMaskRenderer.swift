@preconcurrency import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import Foundation

/// Renders the independent source-coordinate brush-mask pipeline. Masks are
/// composited in array order and each mask's local adjustment is evaluated once
/// against the image produced by the preceding mask.
public enum BrushMaskRenderer {
    public enum Error: Swift.Error, Equatable, Sendable { case renderFailed }
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
            coordinateMapping = try BrushCoordinateMapping(sourceExtent: image.extent, geometry: .neutral)
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
            let blend = CIFilter.blendWithMask()
            blend.inputImage = adjusted.cropped(to: working.extent)
            blend.backgroundImage = working
            blend.maskImage = coverage
            guard let out = blend.outputImage else { throw Error.renderFailed }
            working = out.cropped(to: working.extent)
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
        let width = Int(imageExtent.width.rounded(.up))
        let height = Int(imageExtent.height.rounded(.up))
        guard width > 0, height > 0 else { return CIImage(color: .clear).cropped(to: imageExtent) }
        var alpha = [CGFloat](repeating: 0, count: width * height)
        let shortSide = min(imageExtent.width, imageExtent.height)
        for stroke in mask.strokes {
            let points = try stroke.validated().points
            guard !points.isEmpty, stroke.flow > 0 else { continue }
            let samples = try sample(points: points, stroke: stroke, mapping: mapping)
            for point in samples {
                let feather = min(max(CGFloat(stroke.feather), 0), 1)
                // Feather is a visible falloff band; give it room outside the
                // hard core so a soft brush still affects the boundary pixels.
                let radius = max(CGFloat(stroke.size) * shortSide / 2 * (1 + feather), 0.5)
                // A zero-feather brush is a filled disk. Feather reserves a
                // falloff band outside that disk while preserving the flow
                // value throughout the hard core.
                let innerRadius = radius * (1 - feather)
                let visualY = imageExtent.maxY - (point.y - imageExtent.minY)
                let minX = max(0, Int(floor(point.x - radius - imageExtent.minX - 1)))
                let maxX = min(width - 1, Int(ceil(point.x + radius - imageExtent.minX + 1)))
                let minY = max(0, Int(floor(visualY - radius - imageExtent.minY - 1)))
                let maxY = min(height - 1, Int(ceil(visualY + radius - imageExtent.minY + 1)))
                for y in minY...maxY { for x in minX...maxX {
                    let world = CGPoint(x: imageExtent.minX + CGFloat(x) + 0.5, y: imageExtent.minY + CGFloat(y) + 0.5)
                    let distance = hypot(world.x - point.x, world.y - visualY)
                    let opacity = distance <= innerRadius ? CGFloat(stroke.flow) : (distance < radius ? CGFloat(stroke.flow) * (1 - (distance - innerRadius) / max(radius - innerRadius, 0.0001)) : 0)
                    guard opacity > 0 else { continue }
                    let index = y * width + x
                    alpha[index] = stroke.mode == .paint ? 1 - (1 - alpha[index]) * (1 - opacity) : alpha[index] * (1 - opacity)
                }}
            }
        }
        // CIImage bitmap rows are top-down for R8; the coverage array uses
        // Core Image's y-up pixel rows, so flip exactly once here.
        let bytes = (0..<height).flatMap { row in
            let sourceRow = height - 1 - row
            return (0..<width).map { x in
                UInt8((min(max(alpha[sourceRow * width + x], 0), 1) * 255).rounded())
            }
        }
        let gray = CGColorSpace(name: CGColorSpace.linearGray)
            ?? CGColorSpaceCreateDeviceGray()
        return CIImage(bitmapData: Data(bytes), bytesPerRow: width,
                        size: CGSize(width: width, height: height), format: .R8,
                        colorSpace: gray)
            .transformed(by: CGAffineTransform(translationX: imageExtent.minX, y: imageExtent.minY))
            .cropped(to: imageExtent)
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

}
