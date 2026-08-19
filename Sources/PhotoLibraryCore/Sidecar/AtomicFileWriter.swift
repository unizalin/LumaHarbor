import Foundation
import Localization

public enum AtomicWriteError: Error, Equatable, Sendable {
    case destinationNotWritable(path: String)
    case volumeUnavailable(path: String)
    case insufficientDiskSpace
    case writeFailed(path: String, reason: String)
}

extension AtomicWriteError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .destinationNotWritable:
            return L10n.t("This drive is read-only, so edits can't be saved next to your photos.")
        case .volumeUnavailable:
            return L10n.t("The drive holding this library isn't available.")
        case .insufficientDiskSpace:
            return L10n.t("There isn't enough free space to save your edits.")
        case .writeFailed(_, let reason):
            return "\(L10n.t("Your edits couldn't be saved.")) \(reason)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .destinationNotWritable:
            return L10n.t("Unlock the drive or copy the library somewhere writable, then retry.")
        case .volumeUnavailable:
            return L10n.t("Reconnect the drive, then retry.")
        case .insufficientDiskSpace:
            return L10n.t("Free up space on the drive, then retry.")
        case .writeFailed:
            return L10n.t("Retry saving.")
        }
    }
}

/// Write-to-temp-then-replace, in the destination directory.
///
/// Spec §8.2 requires exactly this shape: a temporary file in the *same*
/// directory (so the replace is a rename on the same volume, not a copy),
/// flushed to disk before it is swapped in. A failure must leave the previous
/// file untouched — the caller then keeps the UI's "saved" state false.
public enum AtomicFileWriter {
    public static func write(
        _ data: Data,
        to url: URL,
        fileManager: FileManager = .default
    ) throws {
        let directory = url.deletingLastPathComponent()

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw mapError(error, path: directory.path)
        }

        guard fileManager.isWritableFile(atPath: directory.path) else {
            throw AtomicWriteError.destinationNotWritable(path: directory.path)
        }

        let temporaryURL = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )

        do {
            guard fileManager.createFile(atPath: temporaryURL.path, contents: nil) else {
                throw AtomicWriteError.destinationNotWritable(path: directory.path)
            }
            let handle = try FileHandle(forWritingTo: temporaryURL)
            do {
                try handle.write(contentsOf: data)
                // Without this the rename can land before the bytes do, and a
                // power loss leaves a valid-looking but empty sidecar.
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }

            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: url)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw mapError(error, path: url.path)
        }
    }

    static func mapError(_ error: Error, path: String) -> Error {
        if let error = error as? AtomicWriteError { return error }
        let nsError = error as NSError

        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileWriteOutOfSpaceError:
                return AtomicWriteError.insufficientDiskSpace
            case NSFileWriteVolumeReadOnlyError, NSFileWriteNoPermissionError:
                return AtomicWriteError.destinationNotWritable(path: path)
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                return AtomicWriteError.volumeUnavailable(path: path)
            default:
                break
            }
        }
        if nsError.domain == NSPOSIXErrorDomain {
            switch Int32(nsError.code) {
            case ENOSPC:
                return AtomicWriteError.insufficientDiskSpace
            case EROFS, EACCES, EPERM:
                return AtomicWriteError.destinationNotWritable(path: path)
            case ENOENT, ENXIO, ENODEV:
                return AtomicWriteError.volumeUnavailable(path: path)
            default:
                break
            }
        }
        return AtomicWriteError.writeFailed(path: path, reason: nsError.localizedDescription)
    }
}
