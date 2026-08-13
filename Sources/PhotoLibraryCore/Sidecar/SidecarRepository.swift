import Foundation
import RawProcessingCore

public enum SidecarError: Error, Equatable, Sendable {
    /// The file parsed but claims a schema this build can't read.
    case unsupportedSchemaVersion(found: Int, supported: Int)
    /// The JSON is unreadable. `quarantinedAt` is the path it was moved to, or
    /// `nil` when the move itself failed (read-only drive).
    case corruptSidecar(photoID: PhotoID, quarantinedAt: String?, reason: String)
    case corruptManifest(quarantinedAt: String?, reason: String)
    case libraryUnavailable(path: String)
    case notWritable(path: String)
    case write(AtomicWriteError)
}

extension SidecarError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let found, let supported):
            return "These edits were saved by a newer version of LumaHarbor "
                + "(format \(found); this version reads up to \(supported))."
        case .corruptSidecar:
            return "The saved edits for this photo are damaged."
        case .corruptManifest:
            return "This library's index file is damaged."
        case .libraryUnavailable:
            return "The drive holding this library isn't available."
        case .notWritable(let path):
            return "\(path) is read-only."
        case .write(let error):
            return error.errorDescription
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .unsupportedSchemaVersion:
            return "Update LumaHarbor, or edit this photo on the device that wrote it."
        case .corruptSidecar:
            return "The damaged file has been set aside and your RAW is untouched. "
                + "Start editing again to write fresh settings."
        case .corruptManifest:
            return "The damaged file has been set aside. Rescan the folder to rebuild it."
        case .libraryUnavailable:
            return "Reconnect the drive, then retry."
        case .notWritable:
            return "Unlock the drive, or copy the library somewhere writable."
        case .write(let error):
            return error.recoverySuggestion
        }
    }
}

public protocol SidecarStoring: Sendable {
    var libraryRootURL: URL { get }
    var isAvailable: Bool { get }
    var isWritable: Bool { get }

    func loadManifest() throws -> LibraryManifest?
    func write(manifest: LibraryManifest) throws
    func loadSidecar(for photoID: PhotoID) throws -> PhotoSidecar?
    func write(sidecar: PhotoSidecar) throws
    func removeSidecar(for photoID: PhotoID) throws
}

/// Reads and writes `.lumaharbor` on the photo drive.
///
/// Spec §8.1 makes this directory the single source of truth for portable data.
/// Two rules follow and are enforced here: writes are atomic, and damaged JSON
/// is quarantined rather than silently replaced.
/// `FileManager` is not annotated `Sendable` by Foundation. This repository
/// only keeps an immutable instance and performs synchronous, non-delegate file
/// operations, so sharing the value across an actor boundary is safe.
public struct FileSidecarRepository: SidecarStoring, @unchecked Sendable {
    public static let directoryName = ".lumaharbor"
    public static let manifestFilename = "library.json"
    public static let editsDirectoryName = "edits"
    public static let quarantineDirectoryName = "quarantine"

    public let libraryRootURL: URL
    private let fileManager: FileManager

    public init(libraryRootURL: URL, fileManager: FileManager = .default) {
        self.libraryRootURL = libraryRootURL
        self.fileManager = fileManager
    }

    public var containerURL: URL {
        libraryRootURL.appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    public var manifestURL: URL {
        containerURL.appendingPathComponent(Self.manifestFilename)
    }

    public var editsDirectoryURL: URL {
        containerURL.appendingPathComponent(Self.editsDirectoryName, isDirectory: true)
    }

    public var quarantineDirectoryURL: URL {
        containerURL.appendingPathComponent(Self.quarantineDirectoryName, isDirectory: true)
    }

    public func sidecarURL(for photoID: PhotoID) -> URL {
        editsDirectoryURL.appendingPathComponent(photoID.sidecarFilename)
    }

    /// Whether the drive is mounted at all — the offline check in spec §10.
    public var isAvailable: Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: libraryRootURL.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// Read-only drives are browsable but not editable (spec §10). Checked
    /// against the root, since `.lumaharbor` may not exist yet.
    public var isWritable: Bool {
        isAvailable && fileManager.isWritableFile(atPath: libraryRootURL.path)
    }

    // MARK: - Manifest

    public func loadManifest() throws -> LibraryManifest? {
        guard isAvailable else {
            throw SidecarError.libraryUnavailable(path: libraryRootURL.path)
        }
        guard fileManager.fileExists(atPath: manifestURL.path) else { return nil }

        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw SidecarError.libraryUnavailable(path: libraryRootURL.path)
        }

        do {
            let manifest = try SidecarCoding.decode(LibraryManifest.self, from: data)
            guard !manifest.isFromNewerSchema else {
                throw SidecarError.unsupportedSchemaVersion(
                    found: manifest.schemaVersion,
                    supported: LibraryManifest.currentSchemaVersion
                )
            }
            return manifest
        } catch let error as SidecarError {
            throw error
        } catch {
            let quarantined = quarantine(manifestURL, label: "library")
            throw SidecarError.corruptManifest(
                quarantinedAt: quarantined?.path,
                reason: (error as NSError).localizedDescription
            )
        }
    }

    public func write(manifest: LibraryManifest) throws {
        try requireWritable()
        do {
            try AtomicFileWriter.write(
                SidecarCoding.encode(manifest),
                to: manifestURL,
                fileManager: fileManager
            )
        } catch let error as AtomicWriteError {
            throw SidecarError.write(error)
        }
    }

    // MARK: - Sidecars

    public func loadSidecar(for photoID: PhotoID) throws -> PhotoSidecar? {
        guard isAvailable else {
            throw SidecarError.libraryUnavailable(path: libraryRootURL.path)
        }
        let url = sidecarURL(for: photoID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SidecarError.libraryUnavailable(path: libraryRootURL.path)
        }

        do {
            let sidecar = try SidecarCoding.decode(PhotoSidecar.self, from: data)
            guard !sidecar.isFromNewerSchema else {
                // Deliberately *not* quarantined: the file is valid, just newer.
                // Overwriting it would destroy edits made on another device.
                throw SidecarError.unsupportedSchemaVersion(
                    found: sidecar.schemaVersion,
                    supported: PhotoSidecar.currentSchemaVersion
                )
            }
            guard sidecar.schemaVersion >= 1 else {
                throw SidecarError.corruptSidecar(
                    photoID: photoID,
                    quarantinedAt: quarantine(url, label: photoID.description)?.path,
                    reason: "Schema version \(sidecar.schemaVersion) is not valid."
                )
            }
            return sidecar
        } catch let error as SidecarError {
            throw error
        } catch {
            // Spec §10: keep the RAW, set the bad JSON aside, surface a
            // diagnosable error. Never silently overwrite.
            let quarantined = quarantine(url, label: photoID.description)
            throw SidecarError.corruptSidecar(
                photoID: photoID,
                quarantinedAt: quarantined?.path,
                reason: (error as NSError).localizedDescription
            )
        }
    }

    public func write(sidecar: PhotoSidecar) throws {
        try requireWritable()
        do {
            try AtomicFileWriter.write(
                SidecarCoding.encode(sidecar),
                to: sidecarURL(for: sidecar.photoID),
                fileManager: fileManager
            )
        } catch let error as AtomicWriteError {
            throw SidecarError.write(error)
        }
    }

    public func removeSidecar(for photoID: PhotoID) throws {
        try requireWritable()
        let url = sidecarURL(for: photoID)
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw SidecarError.write(
                AtomicFileWriter.mapError(error, path: url.path) as? AtomicWriteError
                    ?? .writeFailed(path: url.path, reason: (error as NSError).localizedDescription)
            )
        }
    }

    /// Every `<photo-id>.json` currently on disk. Used to rebuild the local
    /// index when the SQLite database has been deleted.
    public func storedSidecarIDs() throws -> [PhotoID] {
        guard isAvailable else {
            throw SidecarError.libraryUnavailable(path: libraryRootURL.path)
        }
        guard let contents = try? fileManager.contentsOfDirectory(
            at: editsDirectoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return contents.compactMap { url in
            guard url.pathExtension.lowercased() == "json" else { return nil }
            return PhotoID(uuidString: url.deletingPathExtension().lastPathComponent)
        }
    }

    // MARK: - Private

    private func requireWritable() throws {
        guard isAvailable else {
            throw SidecarError.libraryUnavailable(path: libraryRootURL.path)
        }
        guard isWritable else {
            throw SidecarError.notWritable(path: libraryRootURL.path)
        }
    }

    /// Moves a damaged file aside. Returns `nil` if the move fails — the caller
    /// still reports corruption, it just can't promise the file was preserved.
    private func quarantine(_ url: URL, label: String) -> URL? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard isWritable else { return nil }

        let stamp = Self.quarantineTimestampFormatter.string(from: Date())
        let destination = quarantineDirectoryURL
            .appendingPathComponent("\(label)-\(stamp).json")
        do {
            try fileManager.createDirectory(
                at: quarantineDirectoryURL,
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: url, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    private static let quarantineTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
        return formatter
    }()
}
