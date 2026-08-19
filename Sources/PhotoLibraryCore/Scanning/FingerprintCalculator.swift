import CryptoKit
import Foundation

public enum FingerprintError: Error, Equatable, Sendable {
    case fileUnavailable(path: String)
    case readFailed(path: String, reason: String)
}

extension FingerprintError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .fileUnavailable(let path):
            return "\(String(localized: "Couldn't read")) \(path)."
        case .readFailed(_, let reason):
            return "\(String(localized: "Couldn't read the file.")) \(reason)"
        }
    }

    public var recoverySuggestion: String? {
        String(localized: "Reconnect the drive holding this photo, then rescan.")
    }
}

/// Computes `FileFingerprint` values.
///
/// The exact bytes fed to SHA-256 are part of the on-disk format: a stored
/// fingerprint has to keep matching after an app update, or every photo in every
/// library would look like it had changed. The layout is therefore versioned by
/// `domainSeparator` and pinned by tests.
public enum FingerprintCalculator {
    /// How much is read from each end of a large file.
    public static let edgeChunkByteCount = 1 << 20 // 1 MiB
    /// At or below this size the whole file is hashed instead.
    public static let wholeFileThreshold: Int64 = 2 << 20 // 2 MiB
    /// Bumping this invalidates every stored fingerprint by design.
    public static let domainSeparator = "LumaHarborFingerprint/1"

    private static let streamingChunkSize = 1 << 20

    /// Blocking. Spec §11 forbids running this on the main thread.
    public static func fingerprint(forFileAt url: URL) throws -> FileFingerprint {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw FingerprintError.fileUnavailable(path: url.path)
        }
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw FingerprintError.fileUnavailable(path: url.path)
        }
        defer { try? handle.close() }

        do {
            var hasher = SHA256()
            hasher.update(data: header(fileSize: fileSize))

            if fileSize <= wholeFileThreshold {
                // Small file: hash everything, streamed so a surprise large file
                // can't balloon memory if the size attribute lied.
                while let chunk = try handle.read(upToCount: streamingChunkSize), !chunk.isEmpty {
                    // Addendum §3.5: chunk boundaries are the checkpoints that
                    // let a cancelled scan stop mid-file instead of hashing a
                    // whole drive nobody is waiting for.
                    try Task.checkCancellation()
                    hasher.update(data: chunk)
                }
            } else {
                try Task.checkCancellation()
                if let head = try handle.read(upToCount: edgeChunkByteCount) {
                    hasher.update(data: head)
                }
                try Task.checkCancellation()
                try handle.seek(toOffset: UInt64(fileSize - Int64(edgeChunkByteCount)))
                if let tail = try handle.read(upToCount: edgeChunkByteCount) {
                    hasher.update(data: tail)
                }
            }

            return FileFingerprint(fileSize: fileSize, edgeDigest: hexString(hasher.finalize()))
        } catch let error as FingerprintError {
            throw error
        } catch is CancellationError {
            // Propagate as itself: the caller has to tell "you gave up" apart
            // from "this file is unreadable", or a cancelled scan ends up
            // marking healthy photos as damaged.
            throw CancellationError()
        } catch {
            throw FingerprintError.readFailed(
                path: url.path,
                reason: (error as NSError).localizedDescription
            )
        }
    }

    /// Same algorithm over in-memory bytes. Used by tests and by any caller that
    /// already holds the data.
    public static func fingerprint(forData data: Data) -> FileFingerprint {
        let fileSize = Int64(data.count)
        var hasher = SHA256()
        hasher.update(data: header(fileSize: fileSize))

        if fileSize <= wholeFileThreshold {
            hasher.update(data: data)
        } else {
            hasher.update(data: data.prefix(edgeChunkByteCount))
            hasher.update(data: data.suffix(edgeChunkByteCount))
        }
        return FileFingerprint(fileSize: fileSize, edgeDigest: hexString(hasher.finalize()))
    }

    /// Domain tag plus the little-endian size, so two files that share edge bytes
    /// but differ in length can't collide.
    private static func header(fileSize: Int64) -> Data {
        var data = Data(domainSeparator.utf8)
        withUnsafeBytes(of: UInt64(bitPattern: fileSize).littleEndian) { buffer in
            data.append(contentsOf: buffer)
        }
        return data
    }

    private static func hexString(_ digest: SHA256Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
