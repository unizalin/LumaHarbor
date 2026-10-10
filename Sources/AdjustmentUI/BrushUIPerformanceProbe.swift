import Foundation

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// Opt-in runtime bridge between the real brush gesture and the pure heartbeat
/// recorder. It is disabled unless all PERF-UI environment fields are present.
@MainActor
public final class BrushUIPerformanceProbe: NSObject {
    public static let shared = BrushUIPerformanceProbe(
        environment: ProcessInfo.processInfo.environment
    )

    public var isEnabled: Bool { recorder != nil }

    private var recorder: BrushUIHeartbeatRecorder?
    private let writer: BrushUIHeartbeatJSONLWriter?
    private let writerQueue = DispatchQueue(label: "app.lumaharbor.perf-ui-evidence", qos: .utility)
    private var heartbeatTimer: Timer?
    private var observersInstalled = false

    public init(environment: [String: String]) {
        if let configuration = BrushUIPerformanceProbeConfiguration(environment: environment),
           let writer = try? BrushUIHeartbeatJSONLWriter(outputURL: configuration.outputURL) {
            recorder = BrushUIHeartbeatRecorder(configuration: configuration.recorderConfiguration)
            self.writer = writer
        } else {
            recorder = nil
            writer = nil
        }
        super.init()
    }

    public func activate() {
        guard var recorder, heartbeatTimer == nil else { return }
        installLifecycleObserversIfNeeded()

        let now = DispatchTime.now().uptimeNanoseconds
        recorder.recordHeartbeat(atNanoseconds: now)
        self.recorder = recorder

        let interval = TimeInterval(recorder.configuration.expectedHeartbeatIntervalNanoseconds) / 1_000_000_000
        let timer = Timer(
            timeInterval: interval,
            target: self,
            selector: #selector(heartbeatTimerFired),
            userInfo: nil,
            repeats: true
        )
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
    }

    @discardableResult
    public func beginGesture(kind: String) -> UUID? {
        activate()
        guard var recorder else { return nil }
        let id = UUID()
        guard recorder.beginGesture(
            id: id,
            kind: kind,
            atNanoseconds: DispatchTime.now().uptimeNanoseconds
        ) else {
            return nil
        }
        self.recorder = recorder
        return id
    }

    public func requestGestureEnd(id: UUID?) {
        guard let id, var recorder else { return }
        _ = recorder.requestGestureEnd(
            id: id,
            atNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
        self.recorder = recorder
        persistCompletedSamples()
    }

    public func previewFrameBecameVisible() {
        guard var recorder else { return }
        _ = recorder.markVisibleFrame(
            atNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
        self.recorder = recorder
    }

    public func cancelGesture(
        id: UUID?,
        reason: BrushUIGestureCancellationReason
    ) {
        guard var recorder else { return }
        _ = recorder.cancelGesture(
            id: id,
            reason: reason,
            atNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
        self.recorder = recorder
        persistCompletedSamples()
    }

    @objc private func heartbeatTimerFired() {
        guard var recorder else { return }
        recorder.recordHeartbeat(atNanoseconds: DispatchTime.now().uptimeNanoseconds)
        self.recorder = recorder
        persistCompletedSamples()
    }

    private func persistCompletedSamples() {
        guard var recorder else { return }
        let samples = recorder.drainCompletedSamples()
        self.recorder = recorder
        guard !samples.isEmpty, let writer else { return }

        writerQueue.async {
            for sample in samples {
                try? writer.append(sample)
            }
        }
    }

    private func installLifecycleObserversIfNeeded() {
        guard !observersInstalled else { return }
        observersInstalled = true

        #if os(macOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationBecameInactive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationBecameActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
        #elseif os(iOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationBecameInactive),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationBecameActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate),
            name: UIApplication.willTerminateNotification,
            object: nil
        )
        #endif
    }

    @objc private func applicationBecameInactive() {
        cancelGesture(id: nil, reason: .applicationBackgrounded)
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    @objc private func applicationBecameActive() {
        activate()
    }

    @objc private func applicationWillTerminate() {
        cancelGesture(id: nil, reason: .applicationTerminated)
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        guard let writer else { return }
        writerQueue.sync {
            try? writer.synchronize()
        }
    }
}
