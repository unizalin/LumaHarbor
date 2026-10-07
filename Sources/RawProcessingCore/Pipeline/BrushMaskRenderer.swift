@preconcurrency import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import Dispatch
import Foundation

internal struct BrushMaskRenderEvent: Sendable {
    internal enum Kind: Sendable {
        case workerStarted
        case progress
        case workerFinished
    }

    internal enum Stage: Sendable {
        case validation
        case sampling
        case rasterization
        case conversion
    }

    let requestID: UUID
    let maskIndex: Int
    let kind: Kind
    let stage: Stage?
    let completedIterations: Int
}

internal struct BrushMaskRenderObserver: Sendable {
    let requestID: UUID
    private let handler: @Sendable (BrushMaskRenderEvent) -> Void

    init(
        requestID: UUID = UUID(),
        handler: @escaping @Sendable (BrushMaskRenderEvent) -> Void
    ) {
        self.requestID = requestID
        self.handler = handler
    }

    func emit(
        maskIndex: Int,
        kind: BrushMaskRenderEvent.Kind,
        stage: BrushMaskRenderEvent.Stage? = nil,
        completedIterations: Int = 0
    ) {
        handler(BrushMaskRenderEvent(
            requestID: requestID,
            maskIndex: maskIndex,
            kind: kind,
            stage: stage,
            completedIterations: completedIterations
        ))
    }
}

/// Monotonic wall-time interval emitted by a brush worker. Parallel workers
/// are reported as intervals and unioned by the preview renderer; their CPU
/// durations are never summed as if they were wall time.
internal struct BrushMaskStageInterval: Sendable {
    internal enum Stage: Sendable {
        case validationSampling
        case coverageRaster
        case perMaskAdjustmentBlend
    }

    let stage: Stage
    let startNanoseconds: UInt64
    let endNanoseconds: UInt64

    init(stage: Stage, startNanoseconds: UInt64, endNanoseconds: UInt64) {
        self.stage = stage
        self.startNanoseconds = startNanoseconds
        self.endNanoseconds = max(endNanoseconds, startNanoseconds)
    }
}

private final class RasterCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Swift.Error?

    var hasError: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedError != nil
    }

    var error: Swift.Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    func record(_ error: Swift.Error) {
        lock.lock()
        if storedError == nil {
            storedError = error
        }
        lock.unlock()
    }
}

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
        try _applyValidated(
            masks,
            to: image,
            mapping: mapping,
            recipe: recipe,
            scaleFactor: scaleFactor,
            observer: nil,
            cancellationCheck: cancellationCheck
        )
    }

    internal static func _applyValidated(
        _ masks: [BrushMask],
        to image: CIImage,
        mapping: BrushCoordinateMapping? = nil,
        recipe: ResolvedRawRenderRecipe? = nil,
        scaleFactor: Double = 1,
        observer: BrushMaskRenderObserver?,
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
        try validate(
            masks,
            mapping: coordinateMapping,
            observer: observer,
            cancellationCheck: cancellationCheck
        )
        for (maskIndex, mask) in masks.enumerated() where mask.isEnabled {
            try cancellationCheck()
            guard mask.rendererVersion == BrushMask.currentRendererVersion,
                  !mask.adjustments.isNeutral else { continue }
            let coverage = try renderCoverage(
                mask,
                imageExtent: image.extent,
                mapping: coordinateMapping,
                cancellationCheck: cancellationCheck,
                maskIndex: maskIndex,
                observer: observer
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
        try await _applyValidatedAsync(
            masks,
            to: image,
            mapping: mapping,
            recipe: recipe,
            scaleFactor: scaleFactor,
            observer: nil,
            cancellationCheck: cancellationCheck
        )
    }

    internal static func _applyValidatedAsync(
        _ masks: [BrushMask],
        to image: CIImage,
        mapping: BrushCoordinateMapping? = nil,
        recipe: ResolvedRawRenderRecipe? = nil,
        scaleFactor: Double = 1,
        observer: BrushMaskRenderObserver?,
        stageIntervalObserver: (@Sendable (BrushMaskStageInterval) -> Void)? = nil,
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

        let validationStart = DispatchTime.now().uptimeNanoseconds
        try validate(
            masks,
            mapping: coordinateMapping,
            observer: observer,
            cancellationCheck: cancellationCheck
        )
        stageIntervalObserver?(BrushMaskStageInterval(
            stage: .validationSampling,
            startNanoseconds: validationStart,
            endNanoseconds: DispatchTime.now().uptimeNanoseconds
        ))

        let activeMasks = masks.enumerated().filter { _, mask in
            mask.isEnabled
                && mask.rendererVersion == BrushMask.currentRendererVersion
                && !mask.adjustments.isNeutral
        }
        if activeMasks.isEmpty { return image }

        var coverages = Array<CIImage?>(repeating: nil, count: masks.count)
        if activeMasks.count == 1, let (index, mask) = activeMasks.first {
            coverages[index] = try renderCoverage(
                mask,
                imageExtent: image.extent,
                mapping: coordinateMapping,
                cancellationCheck: cancellationCheck,
                maskIndex: index,
                observer: observer,
                stageIntervalObserver: stageIntervalObserver
            )
        } else {
            try await withThrowingTaskGroup(of: (Int, CIImage).self) { group in
                // Bound the number of full-frame coverage scratch buffers that
                // are live at once. Each mask still uses tile-level CPU
                // parallelism; limiting mask fan-out keeps peak RSS stable
                // when several masks share repeated stroke geometry.
                let maxConcurrentMasks = min(2, activeMasks.count)
                var nextMaskIndex = 0
                for _ in 0..<maxConcurrentMasks {
                    let (index, mask) = activeMasks[nextMaskIndex]
                    nextMaskIndex += 1
                    group.addTask {
                        try cancellationCheck()
                        let coverage = try renderCoverage(
                            mask,
                            imageExtent: image.extent,
                            mapping: coordinateMapping,
                            cancellationCheck: cancellationCheck,
                            maskIndex: index,
                            observer: observer,
                            stageIntervalObserver: stageIntervalObserver
                        )
                        try cancellationCheck()
                        return (index, coverage)
                    }
                }
                while let (index, coverage) = try await group.next() {
                    coverages[index] = coverage
                    guard nextMaskIndex < activeMasks.count else { continue }
                    let (nextIndex, nextMask) = activeMasks[nextMaskIndex]
                    nextMaskIndex += 1
                    group.addTask {
                        try cancellationCheck()
                        let coverage = try renderCoverage(
                            nextMask,
                            imageExtent: image.extent,
                            mapping: coordinateMapping,
                            cancellationCheck: cancellationCheck,
                            maskIndex: nextIndex,
                            observer: observer,
                            stageIntervalObserver: stageIntervalObserver
                        )
                        try cancellationCheck()
                        return (nextIndex, coverage)
                    }
                }
            }
        }

        var working = image
        let blendStart = DispatchTime.now().uptimeNanoseconds
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
        stageIntervalObserver?(BrushMaskStageInterval(
            stage: .perMaskAdjustmentBlend,
            startNanoseconds: blendStart,
            endNanoseconds: DispatchTime.now().uptimeNanoseconds
        ))
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

    private static func validate(
        _ masks: [BrushMask],
        mapping: BrushCoordinateMapping,
        observer: BrushMaskRenderObserver?,
        cancellationCheck: @escaping CancellationCheck
    ) throws {
        for (maskIndex, mask) in masks.enumerated() {
            try cancellationCheck()
            guard mask.rendererVersion == BrushMask.currentRendererVersion else {
                throw BrushMaskValidationError.unsupportedRendererVersion(mask.rendererVersion)
            }
            _ = try mask.adjustments.validated()
            var validatedPointCount = 0
            for stroke in mask.strokes {
                for (name, value, range) in [
                    ("size", stroke.size, 0.000_001...1.0),
                    ("feather", stroke.feather, 0.0...1.0),
                    ("flow", stroke.flow, 0.0...1.0),
                    ("density", stroke.density, 0.0...1.0)
                ] {
                    guard value.isFinite, range.contains(value) else {
                        throw BrushMaskValidationError.invalidStrokeParameter(name, value)
                    }
                }
                for point in stroke.points {
                    _ = try point.validated()
                    _ = try mapping.sourceToDisplay(point)
                    validatedPointCount += 1
                    if validatedPointCount.isMultiple(of: 4_096) {
                        observer?.emit(
                            maskIndex: maskIndex,
                            kind: .progress,
                            stage: .validation,
                            completedIterations: validatedPointCount
                        )
                        try cancellationCheck()
                    }
                }
            }
            try cancellationCheck()
        }
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
        bitmapObserver: ((Data) -> Void)? = nil,
        maskIndex: Int = 0,
        observer: BrushMaskRenderObserver? = nil,
        stageIntervalObserver: (@Sendable (BrushMaskStageInterval) -> Void)? = nil
    ) throws -> CIImage {
        observer?.emit(maskIndex: maskIndex, kind: .workerStarted)
        defer { observer?.emit(maskIndex: maskIndex, kind: .workerFinished) }
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

            func hasSameGeometry(as other: CoverageStamp) -> Bool {
                point == other.point
                    && visualY == other.visualY
                    && radius == other.radius
                    && innerRadius == other.innerRadius
                    && radiusSquared == other.radiusSquared
                    && innerRadiusSquared == other.innerRadiusSquared
                    && falloffSlope == other.falloffSlope
                    && falloffIntercept == other.falloffIntercept
                    && flow == other.flow
                    && minX == other.minX
                    && maxX == other.maxX
                    && minY == other.minY
                    && maxY == other.maxY
            }
        }

        let tileSize = 256
        let tileColumns = (width + tileSize - 1) / tileSize
        let tileRows = (height + tileSize - 1) / tileSize
        guard tileColumns > 0, tileRows > 0, tileColumns <= Int.max / tileRows else {
            throw Error.renderFailed
        }
        let samplingStart = DispatchTime.now().uptimeNanoseconds
        var stamps: [CoverageStamp] = []
        var stampStrokeIndices: [Int] = []
        var strokeGeometryGroups = Array(repeating: -1, count: mask.strokes.count)
        var geometryRepresentatives: [[CoverageStamp]] = []
        var geometryUseCounts: [Int] = []
        var tileStamps = Array(repeating: [Int](), count: tileColumns * tileRows)
        var tileEntryCount = 0
        let maxTileEntries = 20_000_000
        let shortSide = min(imageExtent.width, imageExtent.height)
        for (strokeIndex, stroke) in mask.strokes.enumerated() {
            try cancellationCheck()
            let points = stroke.points
            guard !points.isEmpty, stroke.flow > 0 else { continue }
            let samples = try sample(
                points: points,
                stroke: stroke,
                mapping: mapping,
                cancellationCheck: cancellationCheck,
                maskIndex: maskIndex,
                observer: observer
            )
            let strokeStart = stamps.count
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
                stampStrokeIndices.append(strokeIndex)
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

            let strokeStampRange = strokeStart..<stamps.count
            guard !strokeStampRange.isEmpty else { continue }
            let group: Int
            if let existing = geometryRepresentatives.firstIndex(where: { representative in
                representative.count == strokeStampRange.count
                    && zip(representative, strokeStampRange).allSatisfy { representativeStamp, index in
                        representativeStamp.hasSameGeometry(as: stamps[index])
                    }
            }) {
                group = existing
            } else {
                group = geometryRepresentatives.count
                geometryRepresentatives.append(strokeStampRange.map { stamps[$0] })
                geometryUseCounts.append(0)
            }
            geometryUseCounts[group] += 1
            strokeGeometryGroups[strokeIndex] = group
        }

        stageIntervalObserver?(BrushMaskStageInterval(
            stage: .validationSampling,
            startNanoseconds: samplingStart,
            endNanoseconds: DispatchTime.now().uptimeNanoseconds
        ))

        var bytes = [UInt8](repeating: 0, count: pixelCount)
        let rasterStart = DispatchTime.now().uptimeNanoseconds
        let cancellationState = RasterCancellationState()
        let tileConcurrency = min(4, max(1, tileColumns * tileRows))
        let rasterSemaphore = DispatchSemaphore(value: tileConcurrency)
        bytes.withUnsafeMutableBufferPointer { byteBuffer in
            DispatchQueue.concurrentPerform(iterations: tileColumns * tileRows) { tileIndex in
                rasterSemaphore.wait()
                defer { rasterSemaphore.signal() }
                guard !cancellationState.hasError else { return }
                do {
                    try cancellationCheck()
                let tileX = tileIndex % tileColumns
                let tileY = tileIndex / tileColumns
                let tileStartX = tileX * tileSize
                let tileStartY = tileY * tileSize
                let tileWidth = min(tileSize, width - tileStartX)
                let tileHeight = min(tileSize, height - tileStartY)
                let alpha = UnsafeMutableBufferPointer<CGFloat>.allocate(capacity: tileWidth * tileHeight)
                alpha.initialize(repeating: 0)
                defer {
                    alpha.deinitialize()
                    alpha.deallocate()
                }
                var pixelIterations = 0
                var cachedStrokeCoverages: [Int: [Float]] = [:]
                let tileStampIndices = tileStamps[tileIndex]
                var tileStampOffset = 0
                while tileStampOffset < tileStampIndices.count {
                    let firstStampIndex = tileStampIndices[tileStampOffset]
                    let strokeIndex = stampStrokeIndices[firstStampIndex]
                    var nextStrokeOffset = tileStampOffset + 1
                    while nextStrokeOffset < tileStampIndices.count,
                          stampStrokeIndices[tileStampIndices[nextStrokeOffset]] == strokeIndex {
                        nextStrokeOffset += 1
                    }
                    let geometryGroup = strokeGeometryGroups[strokeIndex]
                    if geometryUseCounts[geometryGroup] > 1 {
                        let strokeCoverage: [Float]
                        if let cached = cachedStrokeCoverages[geometryGroup] {
                            strokeCoverage = cached
                        } else {
                            var computed = [Float](repeating: 0, count: tileWidth * tileHeight)
                            for stampOffset in tileStampOffset..<nextStrokeOffset {
                                let stamp = stamps[tileStampIndices[stampOffset]]
                                let pointX = stamp.point.x
                                let pointY = stamp.visualY
                                let innerRadiusSquared = stamp.innerRadiusSquared
                                let radiusSquared = stamp.radiusSquared
                                let falloffIntercept = stamp.falloffIntercept
                                let falloffSlope = stamp.falloffSlope
                                let flow = stamp.flow
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
                                            observer?.emit(
                                                maskIndex: maskIndex,
                                                kind: .progress,
                                                stage: .rasterization,
                                                completedIterations: 4_096
                                            )
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
                                            computed[index] = Float(1 - (1 - CGFloat(computed[index])) * (1 - opacity))
                                        }
                                        pixelX += 1
                                    }
                                }
                            }
                            cachedStrokeCoverages[geometryGroup] = computed
                            strokeCoverage = computed
                        }
                        let isPaint = stamps[firstStampIndex].mode == .paint
                        for index in 0..<(tileWidth * tileHeight) {
                            let opacity = CGFloat(strokeCoverage[index])
                            if opacity > 0 {
                                alpha[index] = isPaint
                                    ? 1 - (1 - alpha[index]) * (1 - opacity)
                                    : alpha[index] * (1 - opacity)
                            }
                        }
                    } else {
                        for stampOffset in tileStampOffset..<nextStrokeOffset {
                            let stamp = stamps[tileStampIndices[stampOffset]]
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
                                        observer?.emit(
                                            maskIndex: maskIndex,
                                            kind: .progress,
                                            stage: .rasterization,
                                            completedIterations: 4_096
                                        )
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
                    }
                    tileStampOffset = nextStrokeOffset
                }
                // CIImage bitmap rows are top-down for R8; the coverage array
                // uses Core Image's y-up pixel rows, so flip exactly once here.
                var conversionIterations = 0
                for localRow in 0..<tileHeight {
                    let globalY = tileStartY + localRow
                    let bitmapRow = height - 1 - globalY
                    for column in 0..<tileWidth {
                        conversionIterations += 1
                        if conversionIterations.isMultiple(of: 4096) {
                            observer?.emit(
                                maskIndex: maskIndex,
                                kind: .progress,
                                stage: .conversion,
                                completedIterations: conversionIterations
                            )
                            try cancellationCheck()
                        }
                        let value = min(max(alpha[localRow * tileWidth + column], 0), 1)
                        byteBuffer[bitmapRow * width + tileStartX + column] = UInt8((value * 255).rounded())
                    }
                }
            } catch {
                cancellationState.record(error)
                }
            }
        }
        if let error = cancellationState.error {
            throw error
        }
        stageIntervalObserver?(BrushMaskStageInterval(
            stage: .coverageRaster,
            startNanoseconds: rasterStart,
            endNanoseconds: DispatchTime.now().uptimeNanoseconds
        ))
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
        cancellationCheck: @escaping CancellationCheck,
        maskIndex: Int,
        observer: BrushMaskRenderObserver?
    ) throws -> [CGPoint] {
        try cancellationCheck()
        guard let first = points.first else { return [] }
        let firstPoint = try mapping.sourceToSourcePixel(first)
        var output = [firstPoint]
        let spacing = max(stroke.size / 8, 1 / min(mapping.sourceExtent.width, mapping.sourceExtent.height))
        var remaining = 0.0
        var previous = firstPoint
        for (pointIndex, point) in points.dropFirst().enumerated() {
            if pointIndex > 0, pointIndex.isMultiple(of: 4096) {
                observer?.emit(
                    maskIndex: maskIndex,
                    kind: .progress,
                    stage: .sampling,
                    completedIterations: pointIndex
                )
                try cancellationCheck()
            }
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
                if output.count.isMultiple(of: 4096) {
                    observer?.emit(
                        maskIndex: maskIndex,
                        kind: .progress,
                        stage: .sampling,
                        completedIterations: output.count
                    )
                    try cancellationCheck()
                }
            }
            remaining = travelled - segment
            previous = current
        }
        if output.last != previous { output.append(previous) }
        try cancellationCheck()
        return output
    }

}
