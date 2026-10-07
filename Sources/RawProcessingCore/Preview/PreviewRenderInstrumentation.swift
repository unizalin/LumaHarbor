import Foundation

/// The mutually exclusive wall-time boundaries used by the preview benchmark.
/// Values are measured on the monotonic clock and are never obtained by
/// summing child-task CPU durations.
internal enum PreviewRenderStage: String, Sendable {
    case rawDecode
    case globalAdjustmentGraph
    case validationSampling
    case coverageRaster
    case perMaskAdjustmentBlend
    case finalMakeCGImage
}

internal struct PreviewStageTimings: Sendable, Equatable {
    internal var rawDecode: Double = 0
    internal var globalAdjustmentGraph: Double = 0
    internal var validationSampling: Double = 0
    internal var coverageRaster: Double = 0
    internal var perMaskAdjustmentBlend: Double = 0
    internal var finalMakeCGImage: Double = 0
    internal var totalMaterialized: Double = 0

    internal init() {}
}

internal final class PreviewStageTimingCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var intervals: [PreviewRenderStage: [(UInt64, UInt64)]] = [:]

    func record(_ stage: PreviewRenderStage, start: UInt64, end: UInt64) {
        lock.lock()
        intervals[stage, default: []].append((start, max(start, end)))
        lock.unlock()
    }

    func record(_ interval: BrushMaskStageInterval) {
        let stage: PreviewRenderStage
        switch interval.stage {
        case .validationSampling:
            stage = .validationSampling
        case .coverageRaster:
            stage = .coverageRaster
        case .perMaskAdjustmentBlend:
            stage = .perMaskAdjustmentBlend
        }
        record(stage, start: interval.startNanoseconds, end: interval.endNanoseconds)
    }

    func duration(for stage: PreviewRenderStage) -> Double {
        lock.lock()
        let values = intervals[stage, default: []].sorted { $0.0 < $1.0 }
        lock.unlock()
        guard !values.isEmpty else { return 0 }

        var unionStart = values[0].0
        var unionEnd = values[0].1
        var nanoseconds: UInt64 = 0
        for (start, end) in values.dropFirst() {
            if start > unionEnd {
                nanoseconds += unionEnd - unionStart
                unionStart = start
                unionEnd = end
            } else {
                unionEnd = max(unionEnd, end)
            }
        }
        nanoseconds += unionEnd - unionStart
        return Double(nanoseconds) / 1_000_000_000
    }
}
