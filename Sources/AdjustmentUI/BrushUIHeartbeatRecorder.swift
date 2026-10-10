import Foundation

public struct BrushUIHeartbeatConfiguration: Equatable, Sendable {
    public let schemaVersion: Int
    public let buildIdentifier: String
    public let variant: String
    public let buildConfiguration: String
    public let fixtureIdentifier: String
    public let expectedHeartbeatIntervalNanoseconds: UInt64
    public let maximumFrameCount: Int

    public init(
        schemaVersion: Int = 1,
        buildIdentifier: String,
        variant: String,
        buildConfiguration: String,
        fixtureIdentifier: String,
        expectedHeartbeatIntervalNanoseconds: UInt64,
        maximumFrameCount: Int = 4_096
    ) {
        precondition(expectedHeartbeatIntervalNanoseconds > 0)
        precondition(maximumFrameCount > 0)
        self.schemaVersion = schemaVersion
        self.buildIdentifier = buildIdentifier
        self.variant = variant
        self.buildConfiguration = buildConfiguration
        self.fixtureIdentifier = fixtureIdentifier
        self.expectedHeartbeatIntervalNanoseconds = expectedHeartbeatIntervalNanoseconds
        self.maximumFrameCount = maximumFrameCount
    }
}

public struct BrushUIPerformanceProbeConfiguration: Equatable, Sendable {
    public let outputURL: URL
    public let recorderConfiguration: BrushUIHeartbeatConfiguration

    public init?(environment: [String: String]) {
        guard let outputPath = environment["LUMAHARBOR_PERF_UI_OUTPUT"],
              !outputPath.isEmpty,
              let variant = environment["LUMAHARBOR_PERF_UI_VARIANT"],
              variant == "B" || variant == "O",
              let buildIdentifier = environment["LUMAHARBOR_PERF_UI_BUILD"],
              !buildIdentifier.isEmpty,
              let buildConfiguration = environment["LUMAHARBOR_PERF_UI_CONFIGURATION"],
              !buildConfiguration.isEmpty,
              let fixtureIdentifier = environment["LUMAHARBOR_PERF_UI_FIXTURE"],
              !fixtureIdentifier.isEmpty else {
            return nil
        }

        let heartbeatNanoseconds: UInt64
        if let rawHeartbeat = environment["LUMAHARBOR_PERF_UI_HEARTBEAT_NS"] {
            guard let parsed = UInt64(rawHeartbeat), parsed > 0 else { return nil }
            heartbeatNanoseconds = parsed
        } else {
            heartbeatNanoseconds = 16_666_667
        }

        let maximumFrameCount: Int
        if let rawMaximum = environment["LUMAHARBOR_PERF_UI_MAX_FRAMES"] {
            guard let parsed = Int(rawMaximum), parsed > 0 else { return nil }
            maximumFrameCount = parsed
        } else {
            maximumFrameCount = 4_096
        }

        outputURL = URL(fileURLWithPath: outputPath)
        recorderConfiguration = BrushUIHeartbeatConfiguration(
            buildIdentifier: buildIdentifier,
            variant: variant,
            buildConfiguration: buildConfiguration,
            fixtureIdentifier: fixtureIdentifier,
            expectedHeartbeatIntervalNanoseconds: heartbeatNanoseconds,
            maximumFrameCount: maximumFrameCount
        )
    }
}

public enum BrushUISampleCompleteness: String, Codable, Equatable, Sendable {
    case complete
    case incomplete
}

public enum BrushUIGestureCancellationReason: String, Codable, Equatable, Sendable {
    case gestureCancelled
    case viewDisappeared
    case applicationBackgrounded
    case applicationTerminated
    case recorderOverflow
    case nonMonotonicClock
    case missingFinalHeartbeat
    case missingHeartbeatIntervals
}

public struct BrushUIHeartbeatFrame: Codable, Equatable, Sendable {
    public let intervalNanoseconds: UInt64
    public let extraDelayNanoseconds: UInt64
    public let missedHeartbeatCount: Int
}

public struct BrushUIGestureSample: Encodable, Equatable, Sendable {
    public let schemaVersion: Int
    public let buildIdentifier: String
    public let variant: String
    public let buildConfiguration: String
    public let fixtureIdentifier: String
    public let gestureKind: String
    public let gestureID: UUID
    public let expectedHeartbeatIntervalNanoseconds: UInt64
    public let monotonicStartNanoseconds: UInt64
    public let pointerUpNanoseconds: UInt64?
    public let visibleFrameNanoseconds: UInt64?
    public let monotonicEndNanoseconds: UInt64
    public let frames: [BrushUIHeartbeatFrame]
    public let completeness: BrushUISampleCompleteness
    public let cancellationReason: BrushUIGestureCancellationReason?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case buildIdentifier
        case variant
        case buildConfiguration
        case fixtureIdentifier
        case gestureKind
        case gestureID
        case expectedHeartbeatIntervalNanoseconds
        case monotonicStartNanoseconds
        case pointerUpNanoseconds
        case visibleFrameNanoseconds
        case monotonicEndNanoseconds
        case frames
        case completeness
        case cancellationReason
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(buildIdentifier, forKey: .buildIdentifier)
        try container.encode(variant, forKey: .variant)
        try container.encode(buildConfiguration, forKey: .buildConfiguration)
        try container.encode(fixtureIdentifier, forKey: .fixtureIdentifier)
        try container.encode(gestureKind, forKey: .gestureKind)
        try container.encode(gestureID, forKey: .gestureID)
        try container.encode(expectedHeartbeatIntervalNanoseconds, forKey: .expectedHeartbeatIntervalNanoseconds)
        try container.encode(monotonicStartNanoseconds, forKey: .monotonicStartNanoseconds)
        if let pointerUpNanoseconds {
            try container.encode(pointerUpNanoseconds, forKey: .pointerUpNanoseconds)
        } else {
            try container.encodeNil(forKey: .pointerUpNanoseconds)
        }
        if let visibleFrameNanoseconds {
            try container.encode(visibleFrameNanoseconds, forKey: .visibleFrameNanoseconds)
        } else {
            try container.encodeNil(forKey: .visibleFrameNanoseconds)
        }
        try container.encode(monotonicEndNanoseconds, forKey: .monotonicEndNanoseconds)
        try container.encode(frames, forKey: .frames)
        try container.encode(completeness, forKey: .completeness)
        if let cancellationReason {
            try container.encode(cancellationReason, forKey: .cancellationReason)
        } else {
            try container.encodeNil(forKey: .cancellationReason)
        }
    }
}

/// Newline-delimited evidence sink. The runtime schedules calls to this type
/// off the main thread so evidence I/O cannot inflate the heartbeat it records.
public final class BrushUIHeartbeatJSONLWriter: @unchecked Sendable {
    private let fileHandle: FileHandle
    private let lock = NSLock()
    private let encoder: JSONEncoder

    public init(outputURL: URL) throws {
        let directory = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        fileHandle = try FileHandle(forWritingTo: outputURL)
        try fileHandle.truncate(atOffset: 0)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    deinit {
        try? fileHandle.close()
    }

    public func append(_ sample: BrushUIGestureSample) throws {
        var data = try encoder.encode(sample)
        data.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        try fileHandle.seekToEnd()
        try fileHandle.write(contentsOf: data)
    }

    public func synchronize() throws {
        lock.lock()
        defer { lock.unlock() }
        try fileHandle.synchronize()
    }
}

/// Pure state machine for the 16 ms foreground UI heartbeat acceptance gate.
///
/// Callers supply monotonic timestamps. Keeping the clock and main-runloop
/// driver outside this type makes the gesture boundaries and fail-closed
/// behavior deterministic under unit test.
public struct BrushUIHeartbeatRecorder: Sendable {
    private struct ActiveGesture: Sendable {
        let id: UUID
        let kind: String
        let startedAtNanoseconds: UInt64
        var pointerUpNanoseconds: UInt64?
        var visibleFrameNanoseconds: UInt64?
        var frames: [BrushUIHeartbeatFrame]
    }

    public let configuration: BrushUIHeartbeatConfiguration
    public private(set) var completedSamples: [BrushUIGestureSample] = []

    private var lastHeartbeatNanoseconds: UInt64?
    private var activeGesture: ActiveGesture?

    public init(configuration: BrushUIHeartbeatConfiguration) {
        self.configuration = configuration
    }

    @discardableResult
    public mutating func beginGesture(
        id: UUID = UUID(),
        kind: String,
        atNanoseconds timestamp: UInt64
    ) -> Bool {
        guard activeGesture == nil else { return false }
        if let lastHeartbeatNanoseconds, timestamp < lastHeartbeatNanoseconds {
            return false
        }
        activeGesture = ActiveGesture(
            id: id,
            kind: kind,
            startedAtNanoseconds: timestamp,
            pointerUpNanoseconds: nil,
            visibleFrameNanoseconds: nil,
            frames: []
        )
        return true
    }

    @discardableResult
    public mutating func markVisibleFrame(
        id: UUID? = nil,
        atNanoseconds timestamp: UInt64
    ) -> Bool {
        guard var gesture = activeGesture,
              id == nil || id == gesture.id,
              let pointerUp = gesture.pointerUpNanoseconds,
              gesture.visibleFrameNanoseconds == nil,
              timestamp >= pointerUp else {
            return false
        }
        gesture.visibleFrameNanoseconds = timestamp
        activeGesture = gesture
        return true
    }

    @discardableResult
    public mutating func requestGestureEnd(
        id: UUID? = nil,
        atNanoseconds timestamp: UInt64
    ) -> Bool {
        guard var gesture = activeGesture,
              id == nil || id == gesture.id,
              gesture.pointerUpNanoseconds == nil,
              timestamp >= gesture.startedAtNanoseconds else {
            return false
        }
        gesture.pointerUpNanoseconds = timestamp
        activeGesture = gesture
        return true
    }

    @discardableResult
    public mutating func cancelGesture(
        id: UUID? = nil,
        reason: BrushUIGestureCancellationReason,
        atNanoseconds timestamp: UInt64
    ) -> Bool {
        guard let gesture = activeGesture,
              id == nil || id == gesture.id else {
            return false
        }
        finish(
            gesture,
            atNanoseconds: max(timestamp, gesture.startedAtNanoseconds),
            completeness: .incomplete,
            reason: reason
        )
        return true
    }

    @discardableResult
    public mutating func markMissingFinalHeartbeat(atNanoseconds timestamp: UInt64) -> Bool {
        guard let gesture = activeGesture, gesture.pointerUpNanoseconds != nil else {
            return false
        }
        finish(
            gesture,
            atNanoseconds: max(timestamp, gesture.startedAtNanoseconds),
            completeness: .incomplete,
            reason: .missingFinalHeartbeat
        )
        return true
    }

    public mutating func recordHeartbeat(atNanoseconds timestamp: UInt64) {
        guard let previous = lastHeartbeatNanoseconds else {
            lastHeartbeatNanoseconds = timestamp
            return
        }

        guard timestamp > previous else {
            if let gesture = activeGesture {
                finish(
                    gesture,
                    atNanoseconds: max(timestamp, gesture.startedAtNanoseconds),
                    completeness: .incomplete,
                    reason: .nonMonotonicClock
                )
            }
            return
        }

        lastHeartbeatNanoseconds = timestamp
        guard var gesture = activeGesture else { return }

        // An interval whose leading edge predates pointer-down includes idle
        // time outside the gesture and cannot be used as gesture evidence.
        if previous >= gesture.startedAtNanoseconds {
            guard gesture.frames.count < configuration.maximumFrameCount else {
                finish(
                    gesture,
                    atNanoseconds: timestamp,
                    completeness: .incomplete,
                    reason: .recorderOverflow
                )
                return
            }

            let interval = timestamp - previous
            let expected = configuration.expectedHeartbeatIntervalNanoseconds
            let remainder = interval % expected
            let roundingThreshold = expected / 2 + expected % 2
            let roundedPeriods = interval / expected + (remainder >= roundingThreshold ? 1 : 0)
            gesture.frames.append(BrushUIHeartbeatFrame(
                intervalNanoseconds: interval,
                extraDelayNanoseconds: interval > expected ? interval - expected : 0,
                missedHeartbeatCount: Int(clamping: roundedPeriods > 0 ? roundedPeriods - 1 : 0)
            ))
            activeGesture = gesture
        }

        if let visibleFrame = gesture.visibleFrameNanoseconds, timestamp >= visibleFrame {
            if gesture.frames.isEmpty {
                finish(
                    gesture,
                    atNanoseconds: timestamp,
                    completeness: .incomplete,
                    reason: .missingHeartbeatIntervals
                )
            } else {
                finish(
                    gesture,
                    atNanoseconds: timestamp,
                    completeness: .complete,
                    reason: nil
                )
            }
        }
    }

    public mutating func drainCompletedSamples() -> [BrushUIGestureSample] {
        defer { completedSamples.removeAll(keepingCapacity: true) }
        return completedSamples
    }

    private mutating func finish(
        _ gesture: ActiveGesture,
        atNanoseconds timestamp: UInt64,
        completeness: BrushUISampleCompleteness,
        reason: BrushUIGestureCancellationReason?
    ) {
        completedSamples.append(BrushUIGestureSample(
            schemaVersion: configuration.schemaVersion,
            buildIdentifier: configuration.buildIdentifier,
            variant: configuration.variant,
            buildConfiguration: configuration.buildConfiguration,
            fixtureIdentifier: configuration.fixtureIdentifier,
            gestureKind: gesture.kind,
            gestureID: gesture.id,
            expectedHeartbeatIntervalNanoseconds: configuration.expectedHeartbeatIntervalNanoseconds,
            monotonicStartNanoseconds: gesture.startedAtNanoseconds,
            pointerUpNanoseconds: gesture.pointerUpNanoseconds,
            visibleFrameNanoseconds: gesture.visibleFrameNanoseconds,
            monotonicEndNanoseconds: timestamp,
            frames: gesture.frames,
            completeness: completeness,
            cancellationReason: reason
        ))
        activeGesture = nil
    }
}
