import Foundation
import PresetCore

/// Atomic, file-backed `PresetRepository` for one scope (spec §8.1, §8.2).
///
/// An actor because concurrent `save`/`delete` calls for the same scope must
/// serialize -- the same reason `PhotoLibraryService` and `ThumbnailProvider`
/// are actors. `FileManager` is not `Sendable`, so it -- and everything that
/// touches it -- stays actor-isolated rather than `nonisolated`; only `scope`
/// (a plain `Sendable` value) is safe to read without hopping onto the actor.
public actor FilePresetRepository: PresetRepository {
    public nonisolated let scope: PresetScope
    private let fileManager: FileManager

    public init(scope: PresetScope, fileManager: FileManager = .default) {
        self.scope = scope
        self.fileManager = fileManager
    }

    private nonisolated var directoryURL: URL { scope.directoryURL }

    private var isAvailable: Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: scope.availabilityAnchorURL.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private var isWritable: Bool {
        isAvailable && fileManager.isWritableFile(atPath: scope.availabilityAnchorURL.path)
    }

    private nonisolated func fileURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString).lhpreset")
    }

    // MARK: - Read

    public func list() async throws -> [PresetDocument] {
        guard isAvailable else {
            throw PresetError.destinationUnavailable(scope.availabilityAnchorURL.path)
        }
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return [] // Directory doesn't exist yet: no presets saved, not an error.
        }
        var documents: [PresetDocument] = []
        for url in entries where url.pathExtension.lowercased() == "lhpreset" {
            // A single unreadable file (damaged, or mid-write from another
            // process) doesn't hide every other preset in the scope -- it's
            // just missing from the list, same as `SidecarStoring` treating a
            // missing file as `nil` rather than failing the whole read.
            if let document = try? decodedDocument(at: url) {
                documents.append(document)
            }
        }
        return documents
    }

    public func load(id: UUID) async throws -> PresetDocument? {
        guard isAvailable else {
            throw PresetError.destinationUnavailable(scope.availabilityAnchorURL.path)
        }
        let url = fileURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try decodedDocument(at: url)
    }

    // MARK: - Write

    public func save(
        _ document: PresetDocument,
        conflict: PresetConflictResolution
    ) async throws -> PresetStoreResult {
        let validated = try document.validated()
        guard isAvailable else {
            throw PresetError.destinationUnavailable(scope.availabilityAnchorURL.path)
        }

        // Read what's already there under this UUID, if anything, before
        // checking writability -- a duplicate-content save must succeed even
        // on a read-only scope, since it writes nothing.
        let url = fileURL(for: validated.id)
        let existing: PresetDocument? = fileManager.fileExists(atPath: url.path)
            ? try? decodedDocument(at: url)
            : nil

        if let existing, presetDocumentsAreCanonicallyEqual(existing, validated) {
            return .duplicateSkipped
        }

        guard isWritable else {
            throw PresetError.readOnlyDestination(scope.availabilityAnchorURL.path)
        }

        if existing != nil {
            switch conflict {
            case .cancel:
                return .cancelled
            case .replace:
                try write(validated, to: url)
                return .replaced
            case .keepBoth:
                var copy = validated
                copy.id = UUID()
                try write(copy, to: fileURL(for: copy.id))
                return .keptBoth(newID: copy.id)
            }
        }

        try write(validated, to: url)
        return .created
    }

    public func delete(id: UUID) async throws {
        guard isAvailable else {
            throw PresetError.destinationUnavailable(scope.availabilityAnchorURL.path)
        }
        let url = fileURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else { return }
        guard isWritable else {
            throw PresetError.readOnlyDestination(scope.availabilityAnchorURL.path)
        }
        try fileManager.removeItem(at: url)
    }

    // MARK: - Private

    private func decodedDocument(at url: URL) throws -> PresetDocument {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PresetError.destinationUnavailable(scope.availabilityAnchorURL.path)
        }
        do {
            let document = try SidecarCoding.decode(PresetDocument.self, from: data)
            return try document.validated()
        } catch let error as PresetError {
            throw error
        } catch {
            throw PresetError.malformedJSON((error as NSError).localizedDescription)
        }
    }

    private func write(_ document: PresetDocument, to url: URL) throws {
        do {
            try AtomicFileWriter.write(
                try SidecarCoding.encode(document),
                to: url,
                fileManager: fileManager
            )
        } catch let error as AtomicWriteError {
            switch error {
            case .destinationNotWritable:
                throw PresetError.readOnlyDestination(scope.availabilityAnchorURL.path)
            case .volumeUnavailable:
                throw PresetError.destinationUnavailable(scope.availabilityAnchorURL.path)
            case .insufficientDiskSpace, .writeFailed:
                throw PresetError.destinationUnavailable(error.errorDescription ?? "\(error)")
            }
        }
    }
}
