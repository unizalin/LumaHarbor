import Foundation
import RawProcessingCore

public struct ScannedFile: Equatable, Sendable {
    public var url: URL
    public var relativePath: String
    public var fileSize: Int64
    public var contentModificationDate: Date?

    public init(
        url: URL,
        relativePath: String,
        fileSize: Int64,
        contentModificationDate: Date? = nil
    ) {
        self.url = url
        self.relativePath = relativePath
        self.fileSize = fileSize
        self.contentModificationDate = contentModificationDate
    }
}

public struct ScanSummary: Equatable, Sendable {
    public var discoveredCount: Int
    public var failedCount: Int
    public var completedAt: Date
    /// `true` when the stream ended because the caller cancelled it.
    public var wasCancelled: Bool
}

public enum ScanEvent: Sendable {
    case started
    /// A batch, so the UI can grow the grid incrementally (spec §6.1) rather
    /// than waiting for the whole tree.
    case discovered([ScannedFile])
    /// One file failed. Spec §10: the scan keeps going.
    case fileFailed(relativePath: String, reason: String)
    case finished(ScanSummary)
}

/// Streams a photo folder in batches.
///
/// Spec §11: never load every RAW or all metadata into memory at once. The
/// enumerator is lazy and only the current batch is held, so a 100k-file drive
/// costs the same as a 100-file one.
public struct FolderScanner: Sendable {
    public var supportedExtensions: Set<String>
    public var batchSize: Int

    public init(
        supportedExtensions: Set<String> = CoreImageRawDecoder.candidateFileExtensions,
        batchSize: Int = 32
    ) {
        self.supportedExtensions = supportedExtensions
        self.batchSize = max(1, batchSize)
    }

    public func scan(root: URL) -> AsyncStream<ScanEvent> {
        let supportedExtensions = self.supportedExtensions
        let batchSize = self.batchSize

        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task.detached(priority: .utility) {
                continuation.yield(.started)
                // Foundation's DirectoryEnumerator is explicitly unavailable
                // from async contexts in Swift 6. Isolate the blocking walk in
                // a synchronous helper while this detached task owns it.
                let summary = Self.enumerateSynchronously(
                    root: root,
                    supportedExtensions: supportedExtensions,
                    batchSize: batchSize,
                    continuation: continuation
                )
                continuation.yield(.finished(summary))
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private static func enumerateSynchronously(
        root: URL,
        supportedExtensions: Set<String>,
        batchSize: Int,
        continuation: AsyncStream<ScanEvent>.Continuation
    ) -> ScanSummary {
        var discovered = 0
        var failed = 0
        var batch: [ScannedFile] = []
        batch.reserveCapacity(batchSize)

        let resourceKeys: [URLResourceKey] = [
            .isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isDirectoryKey
        ]

        // `.skipsHiddenFiles` also keeps `.lumaharbor` out of the results,
        // which is exactly what we want: it's our data, not the user's.
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, error in
                failed += 1
                continuation.yield(.fileFailed(
                    relativePath: Self.relativePath(of: url, from: root),
                    reason: (error as NSError).localizedDescription
                ))
                return true // keep going
            }
        )

        guard let enumerator else {
            return ScanSummary(
                discoveredCount: 0,
                failedCount: failed,
                completedAt: Date(),
                wasCancelled: false
            )
        }

        for case let fileURL as URL in enumerator {
            if Task.isCancelled { break }

            guard supportedExtensions.contains(fileURL.pathExtension.lowercased()) else {
                continue
            }

            do {
                let values = try fileURL.resourceValues(forKeys: Set(resourceKeys))
                guard values.isRegularFile == true else { continue }

                batch.append(ScannedFile(
                    url: fileURL,
                    relativePath: Self.relativePath(of: fileURL, from: root),
                    fileSize: Int64(values.fileSize ?? 0),
                    contentModificationDate: values.contentModificationDate
                ))
                discovered += 1
            } catch {
                failed += 1
                continuation.yield(.fileFailed(
                    relativePath: Self.relativePath(of: fileURL, from: root),
                    reason: (error as NSError).localizedDescription
                ))
                continue
            }

            if batch.count >= batchSize {
                continuation.yield(.discovered(batch))
                batch.removeAll(keepingCapacity: true)
            }
        }

        if !batch.isEmpty {
            continuation.yield(.discovered(batch))
        }

        return ScanSummary(
            discoveredCount: discovered,
            failedCount: failed,
            completedAt: Date(),
            wasCancelled: Task.isCancelled
        )
    }

    /// Library-relative, `/`-separated, so the value stored in the sidecar is
    /// portable between this Mac and a future iPad.
    static func relativePath(of url: URL, from root: URL) -> String {
        let rootComponents = root.standardizedFileURL.pathComponents
        let fileComponents = url.standardizedFileURL.pathComponents

        guard fileComponents.count > rootComponents.count,
              Array(fileComponents.prefix(rootComponents.count)) == rootComponents else {
            return url.lastPathComponent
        }
        return fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }
}
