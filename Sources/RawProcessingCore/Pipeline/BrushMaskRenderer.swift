@preconcurrency import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import Foundation

/// Renders the independent source-coordinate brush-mask pipeline. Masks are
/// composited in array order and each mask's local adjustment is evaluated once
/// against the image produced by the preceding mask.
public enum BrushMaskRenderer {
    public enum Error: Swift.Error, Equatable, Sendable { case renderFailed }
    public typealias CancellationCheck = @Sendable () throws -> Void

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
        scaleFactor: Double = 1,
        cancellationCheck: @escaping CancellationCheck = { try Task.checkCancellation() }
    ) throws -> CIImage {
        guard !masks.isEmpty, image.extent.width > 0, image.extent.height > 0 else { return image }
        try cancellationCheck()
        var working = image
        let coordinateMapping: BrushCoordinateMapping
        if let mapping {
            coordinateMapping = mapping
        } else {
            coordinateMapping = try BrushCoordinateMapping(sourceExtent: image.extent, geometry: .neutral)
        }
        for mask in masks {
            try cancellationCheck()
            _ = try mask.validated()
            for stroke in mask.strokes where !stroke.points.isEmpty {
                for point in stroke.points {
                    try cancellationCheck()
                    _ = try coordinateMapping.sourceToDisplay(point)
                }
            }
        }
        for mask in masks where mask.isEnabled {
            try cancellationCheck()
            guard mask.rendererVersion == BrushMask.currentRendererVersion,
                  !mask.adjustments.isNeutral else { continue }
            let coverage = try renderCoverage(
                mask,
                imageExtent: image.extent,
                mapping: coordinateMapping,
                cancellationCheck: cancellationCheck
            )
            try cancellationCheck()
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

    /// Async production entry point. Coverage for independent masks is
    /// rendered in parallel, then composited in the original mask order so
    /// paint/erase and adjustment semantics remain deterministic. Preview and
    /// export call this variant from their detached worker task; the sync
    /// entry point remains available for small callers and unit tests.
    public static func applyValidatedAsync(
        _ masks: [BrushMask],
        to image: CIImage,
        mapping: BrushCoordinateMapping? = nil,
        recipe: ResolvedRawRenderRecipe? = nil,
        scaleFactor: Double = 1,
        cancellationCheck: @escaping CancellationCheck = { try Task.checkCancellation() }
    ) async throws -> CIImage {
        guard !masks.isEmpty, image.extent.width > 0, image.extent.height > 0 else { return image }
        try cancellationCheck()
        let coordinateMapping: BrushCoordinateMapping
        if let mapping {
            coordinateMapping = mapping
        } else {
            coordinateMapping = try BrushCoordinateMapping(sourceExtent: image.extent, geometry: .neutral)
        }

        for mask in masks {
            try cancellationCheck()
            _ = try mask.validated()
            for stroke in mask.strokes where !stroke.points.isEmpty {
                for point in stroke.points {
                    try cancellationCheck()
                    _ = try coordinateMapping.sourceToDisplay(point)
                }
            }
        }

        let activeMasks = masks.enumerated().filter { _, mask in
            mask.isEnabled
                && mask.rendererVersion == BrushMask.currentRendererVersion
                && !mask.adjustments.isNeutral
        }
        if activeMasks.isEmpty { return image }

        struct CoverageResult: @unchecked Sendable {
            let index: Int
            let image: CIImage
        }
        var coverages = Array<CIImage?>(repeating: nil, count: masks.count)
        if activeMasks.count == 1, let (index, mask) = activeMasks.first {
            coverages[index] = try renderCoverage(
                mask,
                imageExtent: image.extent,
                mapping: coordinateMapping,
                cancellationCheck: cancellationCheck
            )
        } else {
            try await withThrowingTaskGroup(of: CoverageResult.self) { group in
                for (index, mask) in activeMasks {
                    group.addTask {
                        try cancellationCheck()
                        let coverage = try renderCoverage(
                            mask,
                            imageExtent: image.extent,
                            mapping: coordinateMapping,
                            cancellationCheck: cancellationCheck
                        )
                        try cancellationCheck()
                        return CoverageResult(index: index, image: coverage)
                    }
                }
                for try await result in group {
                    coverages[result.index] = result.image
                }
            }
        }

        var working = image
        for (index, mask) in activeMasks {
            try cancellationCheck()
            guard let coverage = coverages[index] else { throw Error.renderFailed }
            let parameters = parameters(for: mask.adjustments)
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

    /// Test-only coverage entry point used by the deterministic performance
    /// harness. Product callers must use `applyValidated` so adjustment and
    /// blend stages cannot be bypassed accidentally.
    internal static func _testRenderCoverage(
        _ mask: BrushMask,
        imageExtent: CGRect,
        mapping: BrushCoordinateMapping? = nil,
        cancellationCheck: @escaping CancellationCheck = { try Task.checkCancellation() }
    ) throws -> CIImage {
        let resolvedMapping: BrushCoordinateMapping
        if let mapping {
            resolvedMapping = mapping
        } else {
            resolvedMapping = try BrushCoordinateMapping(sourceExtent: imageExtent, geometry: .neutral)
        }
        return try renderCoverage(
            mask,
            imageExtent: imageExtent,
            mapping: resolvedMapping,
            cancellationCheck: cancellationCheck
        )
    }

    /// Returns the exact R8 storage produced by the tiled rasterizer before
    /// Core Image interprets its row order. This keeps byte-for-byte oracle
    /// tests independent from a second render pass that may normalize image
    /// orientation.
    internal static func _testRenderCoverageBytes(
        _ mask: BrushMask,
        imageExtent: CGRect,
        mapping: BrushCoordinateMapping? = nil,
        cancellationCheck: @escaping CancellationCheck = { try Task.checkCancellation() }
    ) throws -> Data {
        let resolvedMapping: BrushCoordinateMapping
        if let mapping {
            resolvedMapping = mapping
        } else {
            resolvedMapping = try BrushCoordinateMapping(sourceExtent: imageExtent, geometry: .neutral)
        }
        var bitmap = Data()
        _ = try renderCoverage(
            mask,
            imageExtent: imageExtent,
            mapping: resolvedMapping,
            cancellationCheck: cancellationCheck,
            bitmapObserver: { bitmap = $0 }
        )
        return bitmap
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
        mapping: BrushCoordinateMapping,
        cancellationCheck: @escaping CancellationCheck,
        bitmapObserver: ((Data) -> Void)? = nil
    ) throws -> CIImage {
        guard imageExtent.width.isFinite, imageExtent.height.isFinite,
              imageExtent.width > 0, imageExtent.height > 0,
              imageExtent.width < CGFloat(Int.max), imageExtent.height < CGFloat(Int.max)
        else { throw Error.renderFailed }
        let width = Int(imageExtent.width.rounded(.up))
        let height = Int(imageExtent.height.rounded(.up))
        guard width > 0, height > 0, width <= Int.max / height else { throw Error.renderFailed }
        let pixelCount = width * height
        // A coverage image is ultimately an R8 bitmap. Keep its bounded output
        // allocation, rather than recreating the old full-frame CGFloat alpha
        // buffer, and reject unreasonable extents before allocating.
        guard pixelCount <= 200_000_000 else { throw Error.renderFailed }

        struct CoverageStamp {
            let point: CGPoint
            let visualY: CGFloat
            let radius: CGFloat
            let innerRadius: CGFloat
            let radiusSquared: CGFloat
            let innerRadiusSquared: CGFloat
            let falloffSlope: CGFloat
            let falloffIntercept: CGFloat
            let flow: CGFloat
            let mode: BrushMaskStrokeMode
            let minX: Int
            let maxX: Int
            let minY: Int
            let maxY: Int
        }

        let tileSize = 128
        let tileColumns = (width + tileSize - 1) / tileSize
        let tileRows = (height + tileSize - 1) / tileSize
        guard tileColumns > 0, tileRows > 0, tileColumns <= Int.max / tileRows else {
            throw Error.renderFailed
        }
        var stamps: [CoverageStamp] = []
        var tileStamps = Array(repeating: [Int](), count: tileColumns * tileRows)
        var tileEntryCount = 0
        let maxTileEntries = 20_000_000
        let shortSide = min(imageExtent.width, imageExtent.height)
        for stroke in mask.strokes {
            try cancellationCheck()
            let points = try stroke.validated().points
            guard !points.isEmpty, stroke.flow > 0 else { continue }
            let samples = try sample(
                points: points,
                stroke: stroke,
                mapping: mapping,
                cancellationCheck: cancellationCheck
            )
            for (sampleIndex, point) in samples.enumerated() {
                if sampleIndex.isMultiple(of: 4096) { try cancellationCheck() }
                let feather = min(max(CGFloat(stroke.feather), 0), 1)
                // Feather is a visible falloff band; give it room outside the
                // hard core so a soft brush still affects the boundary pixels.
                let radius = max(CGFloat(stroke.size) * shortSide / 2 * (1 + feather), 0.5)
                // A zero-feather brush is a filled disk. Feather reserves a
                // falloff band outside that disk while preserving the flow
                // value throughout the hard core.
                let innerRadius = radius * (1 - feather)
                let falloffDenominator = max(radius - innerRadius, 0.0001)
                let flow = CGFloat(stroke.flow)
                let visualY = imageExtent.maxY - (point.y - imageExtent.minY)
                let minX = max(0, Int(floor(point.x - radius - imageExtent.minX - 1)))
                let maxX = min(width - 1, Int(ceil(point.x + radius - imageExtent.minX + 1)))
                let minY = max(0, Int(floor(visualY - radius - imageExtent.minY - 1)))
                let maxY = min(height - 1, Int(ceil(visualY + radius - imageExtent.minY + 1)))
                guard minX <= maxX, minY <= maxY else { continue }
                let stampIndex = stamps.count
                stamps.append(CoverageStamp(
                    point: point,
                    visualY: visualY,
                    radius: radius,
                    innerRadius: innerRadius,
                    radiusSquared: radius * radius,
                    innerRadiusSquared: innerRadius * innerRadius,
                    falloffSlope: flow / falloffDenominator,
                    falloffIntercept: flow * (1 + innerRadius / falloffDenominator),
                    flow: flow,
                    mode: stroke.mode,
                    minX: minX,
                    maxX: maxX,
                    minY: minY,
                    maxY: maxY
                ))
                let firstTileX = minX / tileSize
                let lastTileX = maxX / tileSize
                let firstTileY = minY / tileSize
                let lastTileY = maxY / tileSize
                let tileSpan = (lastTileX - firstTileX + 1) * (lastTileY - firstTileY + 1)
                guard tileEntryCount <= maxTileEntries - tileSpan else { throw Error.renderFailed }
                for tileY in firstTileY...lastTileY {
                    for tileX in firstTileX...lastTileX {
                        tileStamps[tileY * tileColumns + tileX].append(stampIndex)
                    }
                }
                tileEntryCount += tileSpan
            }
        }

        var bytes = [UInt8](repeating: 0, count: pixelCount)
        for tileY in 0..<tileRows {
            for tileX in 0..<tileColumns {
                try cancellationCheck()
                let tileStartX = tileX * tileSize
                let tileStartY = tileY * tileSize
                let tileWidth = min(tileSize, width - tileStartX)
                let tileHeight = min(tileSize, height - tileStartY)
                var alpha = [CGFloat](repeating: 0, count: tileWidth * tileHeight)
                var pixelIterations = 0
                for stampIndex in tileStamps[tileY * tileColumns + tileX] {
                    let stamp = stamps[stampIndex]
                    let pointX = stamp.point.x
                    let pointY = stamp.visualY
                    let innerRadiusSquared = stamp.innerRadiusSquared
                    let radiusSquared = stamp.radiusSquared
                    let falloffIntercept = stamp.falloffIntercept
                    let falloffSlope = stamp.falloffSlope
                    let flow = stamp.flow
                    let isPaint = stamp.mode == .paint
                    let startX = max(stamp.minX, tileStartX)
                    let endX = min(stamp.maxX, tileStartX + tileWidth - 1)
                    let startY = max(stamp.minY, tileStartY)
                    let endY = min(stamp.maxY, tileStartY + tileHeight - 1)
                    guard startX <= endX, startY <= endY else { continue }
                    for y in startY...endY {
                        let rowY = imageExtent.minY + CGFloat(y) + 0.5
                        let dy = rowY - pointY
                        let dySquared = dy * dy
                        var pixelX = imageExtent.minX + CGFloat(startX) + 0.5
                        for x in startX...endX {
                            pixelIterations += 1
                            if pixelIterations == 4096 {
                                try cancellationCheck()
                                pixelIterations = 0
                            }
                            let dx = pixelX - pointX
                            let distanceSquared = dx * dx + dySquared
                            let opacity: CGFloat
                            if distanceSquared <= innerRadiusSquared {
                                opacity = flow
                            } else if distanceSquared < radiusSquared {
                                let distance = distanceSquared.squareRoot()
                                opacity = falloffIntercept - distance * falloffSlope
                            } else {
                                opacity = 0
                            }
                            if opacity > 0 {
                                let index = (y - tileStartY) * tileWidth + (x - tileStartX)
                                alpha[index] = isPaint
                                    ? 1 - (1 - alpha[index]) * (1 - opacity)
                                    : alpha[index] * (1 - opacity)
                            }
                            pixelX += 1
                        }
                    }
                }
                // CIImage bitmap rows are top-down for R8; the coverage array
                // uses Core Image's y-up pixel rows, so flip exactly once here.
                var conversionIterations = 0
                for localRow in 0..<tileHeight {
                    let globalY = tileStartY + localRow
                    let bitmapRow = height - 1 - globalY
                    for column in 0..<tileWidth {
                        conversionIterations += 1
                        if conversionIterations.isMultiple(of: 4096) { try cancellationCheck() }
                        let value = min(max(alpha[localRow * tileWidth + column], 0), 1)
                        bytes[bitmapRow * width + tileStartX + column] = UInt8((value * 255).rounded())
                    }
                }
            }
        }
        let gray = CGColorSpace(name: CGColorSpace.linearGray)
            ?? CGColorSpaceCreateDeviceGray()
        let bitmap = Data(bytes)
        bitmapObserver?(bitmap)
        return CIImage(bitmapData: bitmap, bytesPerRow: width,
                        size: CGSize(width: width, height: height), format: .R8,
                        colorSpace: gray)
            .transformed(by: CGAffineTransform(translationX: imageExtent.minX, y: imageExtent.minY))
            .cropped(to: imageExtent)
    }

    private static func sample(
        points: [BrushMaskPoint],
        stroke: BrushMaskStroke,
        mapping: BrushCoordinateMapping,
        cancellationCheck: @escaping CancellationCheck
    ) throws -> [CGPoint] {
        try cancellationCheck()
        guard let first = points.first else { return [] }
        let firstPoint = try mapping.sourceToSourcePixel(first)
        var output = [firstPoint]
        let spacing = max(stroke.size / 8, 1 / min(mapping.sourceExtent.width, mapping.sourceExtent.height))
        var remaining = 0.0
        var previous = firstPoint
        for (pointIndex, point) in points.dropFirst().enumerated() {
            if pointIndex.isMultiple(of: 4096) { try cancellationCheck() }
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
                if output.count.isMultiple(of: 4096) { try cancellationCheck() }
            }
            remaining = travelled - segment
            previous = current
        }
        if output.last != previous { output.append(previous) }
        try cancellationCheck()
        return output
    }

}
