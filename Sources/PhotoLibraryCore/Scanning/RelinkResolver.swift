import Foundation

/// What a scanner should do with a file it just found.
public enum RelinkDecision: Equatable, Sendable {
    /// Same path, same content.
    case unchanged(PhotoID)
    /// Same path, different bytes — the file was replaced or re-copied.
    case contentChanged(PhotoID)
    /// New path, exactly one fingerprint match: the photo moved.
    case moved(PhotoID, previousRelativePath: String)
    /// Several records share this fingerprint. Spec §8.1 forbids picking one.
    case ambiguous([PhotoID])
    case new
}

/// Decides identity for a scanned file.
///
/// Pure, so the whole matrix — moved, duplicated, edited-in-place, brand new —
/// is testable without a file system.
public enum RelinkResolver {
    public static func resolve(
        relativePath: String,
        fingerprint: FileFingerprint,
        against records: [PhotoRecord]
    ) -> RelinkDecision {
        // Path is the strongest signal: a file at the path we last saw it is the
        // same photo even if the user re-exported it with different bytes.
        if let atPath = records.first(where: { $0.relativePath == relativePath }) {
            return atPath.fingerprint == fingerprint
                ? .unchanged(atPath.photoID)
                : .contentChanged(atPath.photoID)
        }

        // No path match: the file is new here, moved, or a copy of something else.
        let matches = records.filter { $0.fingerprint == fingerprint }
        switch matches.count {
        case 0:
            return .new
        case 1:
            guard let match = matches.first else { return .new }
            return .moved(match.photoID, previousRelativePath: match.relativePath)
        default:
            // Duplicates on disk. Merging automatically would silently attach one
            // photo's edits to another file, so surface it instead.
            return .ambiguous(matches.map(\.photoID).sorted { $0.description < $1.description })
        }
    }
}
