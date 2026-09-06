import Foundation
import Localization

/// One batch export item's lifecycle (design spec §6.11: "per-file 成功/
/// 失敗報告"; roadmap Phase 5 Task 5.1: "pending/running/succeeded/failed/
/// cancelled"). `succeeded` carries the same `ExportOutcome` a single-photo
/// export returns; `failed` carries a safe, pre-rendered description rather
/// than a boxed `Error` so this type stays `Equatable` and `Sendable`
/// without pulling arbitrary error types into that requirement.
public enum BatchExportItemStatus: Equatable, Sendable {
    case pending
    case running
    case succeeded(ExportOutcome)
    case failed(String)
    case cancelled
    /// `.skip` collision policy and a file already sits at this item's
    /// destination name (roadmap Phase 5 Task 5.2). Its own distinct
    /// terminal state -- not `.succeeded` (nothing was written) and not
    /// `.failed` (nothing went wrong; this is the user's own chosen
    /// policy), matching design spec §8.3's "failed / skipped / not run
    /// 不得偽裝成成功".
    case skipped

    public var isFinished: Bool {
        switch self {
        case .pending, .running: return false
        case .succeeded, .failed, .cancelled, .skipped: return true
        }
    }
}

/// One file in a batch export run, paired with its live status.
public struct BatchExportItem: Sendable {
    public let id: UUID
    public var request: ExportRequest
    public var status: BatchExportItemStatus

    public init(id: UUID = UUID(), request: ExportRequest, status: BatchExportItemStatus = .pending) {
        self.id = id
        self.request = request
        self.status = status
    }
}

/// One file's entry in a finished (or cancelled) batch's per-file report.
public struct BatchExportFileResult: Sendable, Equatable {
    public var sourceURL: URL
    public var baseFilename: String
    public var status: BatchExportItemStatus
}

/// The per-file success/failure report design spec §6.11 asks for, produced
/// once `BatchExportQueue.run(_:onUpdate:)` finishes.
public struct BatchExportReport: Sendable, Equatable {
    public var files: [BatchExportFileResult]

    public init(items: [BatchExportItem]) {
        files = items.map {
            BatchExportFileResult(sourceURL: $0.request.sourceURL, baseFilename: $0.request.baseFilename, status: $0.status)
        }
    }

    public var succeededCount: Int {
        files.filter { if case .succeeded = $0.status { return true }; return false }.count
    }

    public var failedCount: Int {
        files.filter { if case .failed = $0.status { return true }; return false }.count
    }

    public var cancelledCount: Int {
        files.filter { $0.status == .cancelled }.count
    }

    public var skippedCount: Int {
        files.filter { $0.status == .skipped }.count
    }
}

/// Drives a sequential batch export (roadmap Phase 5 Task 5.1), reusing the
/// same `PhotoExporter` a single-photo export already goes through so every
/// per-file guarantee it makes -- full-resolution re-decode, no silent
/// overwrite, no partial output left behind on cancellation -- applies to
/// every file in the batch, not just the first.
///
/// Deliberately sequential rather than concurrent: exports are already
/// disk- and CPU-bound (spec §11: no decoding/encoding on the main thread),
/// and running one at a time keeps per-file progress reporting exact --
/// no report has to reconcile two files finishing out of order.
///
/// Cancellation is cooperative, the same pattern `PhotoExporter` itself
/// uses: cancel the `Task` that is awaiting `run(_:onUpdate:)`, not this
/// actor. The currently-running item observes that cancellation the same
/// way a single export does (via `Task.isCancelled` inside `PhotoExporter`,
/// which already cleans up its own temp file before rethrowing), and every
/// item that had not yet started is marked `.cancelled` without ever
/// reaching the exporter -- so a cancelled batch can never leave a temp
/// file behind for any file, started or not.
public actor BatchExportQueue {
    private let exporter: PhotoExporter

    public init(exporter: PhotoExporter = PhotoExporter()) {
        self.exporter = exporter
    }

    /// Runs every request in order. `onUpdate` is awaited after the initial
    /// all-`.pending` snapshot and again after every subsequent status
    /// change, so a caller (typically hopping onto `@MainActor` inside the
    /// closure) can render live per-file progress without polling.
    @discardableResult
    public func run(
        _ requests: [ExportRequest],
        onUpdate: (@Sendable ([BatchExportItem]) async -> Void)? = nil
    ) async -> BatchExportReport {
        var items = requests.map { BatchExportItem(request: $0) }
        await onUpdate?(items)

        for index in items.indices {
            if Task.isCancelled {
                items[index].status = .cancelled
                await onUpdate?(items)
                continue
            }

            items[index].status = .running
            await onUpdate?(items)

            do {
                let outcome = try await exporter.export(items[index].request)
                items[index].status = .succeeded(outcome)
            } catch ExportError.skippedExistingFile {
                // The user's own `.skip` collision policy doing exactly
                // what it says -- never counted as `.failed`.
                items[index].status = .skipped
            } catch {
                items[index].status = Task.isCancelled ? .cancelled : .failed(Self.safeDescription(for: error))
            }
            await onUpdate?(items)
        }

        return BatchExportReport(items: items)
    }

    /// Never forwards an unrecognized error's own `errorDescription`/
    /// `localizedDescription` -- a bare `NSError` (e.g. from `FileManager`)
    /// routinely embeds an absolute path in that text. Only `ExportError`
    /// and `RawDecodingError` are known well enough here to forward their
    /// own `errorDescription` case by case, and `RawDecodingError
    /// .fileUnavailable`'s `errorDescription` is the one case in this whole
    /// module that embeds the source file's absolute path (see
    /// `RawDecodingError.swift`), so it gets a fixed, path-free string
    /// instead. Mirrors `EditorCore/SafeErrorPresentation.swift`'s
    /// convention and reuses the same already-localized strings, without
    /// adding a dependency on `EditorCore` itself.
    private static func safeDescription(for error: Error) -> String {
        if error is CancellationError {
            return L10n.t("The operation was cancelled.")
        }
        if let exportError = error as? ExportError {
            return safeDescription(for: exportError)
        }
        if let decodingError = error as? RawDecodingError {
            return safeDescription(for: decodingError)
        }
        return L10n.t("Something went wrong.")
    }

    private static func safeDescription(for error: ExportError) -> String {
        switch error {
        case .decoding(let decodingError):
            return safeDescription(for: decodingError)
        case .destinationNotWritable, .destinationUnavailable, .couldNotFindUniqueName,
             .insufficientDiskSpace, .cancelled, .rendering, .formatNotSupported,
             .skippedExistingFile, .collisionPolicyNotSupported:
            // Every other case's own `errorDescription` has been read end to
            // end and never embeds a path -- verified again here rather than
            // assumed, the same discipline `SafeErrorPresentation` uses.
            return error.errorDescription ?? L10n.t("Something went wrong.")
        }
    }

    private static func safeDescription(for error: RawDecodingError) -> String {
        switch error {
        case .fileUnavailable:
            return L10n.t("The original file isn't available right now.")
        case .unsupportedFormat:
            return L10n.t("This camera's RAW format isn't supported yet.")
        case .corruptedFile:
            return L10n.t("This RAW file appears to be damaged.")
        case .decodeFailed:
            // `reason` is a system/decoder-supplied string of unknown
            // provenance and is not trusted to be path-free, so it is never
            // forwarded -- same call `SafeErrorPresentation` makes.
            return L10n.t("The RAW file couldn't be decoded.")
        case .cancelled:
            return L10n.t("The operation was cancelled.")
        }
    }
}
