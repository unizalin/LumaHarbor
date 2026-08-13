import Foundation

/// Cheap content identity for a RAW file.
///
/// Spec §8.1: size plus a SHA-256 over the first and last 1 MiB. Files under
/// 2 MiB are hashed whole. This exists to relink moved files and detect
/// changed ones — it never replaces the `PhotoID`.
public struct FileFingerprint: Hashable, Codable, Sendable {
    public let fileSize: Int64
    /// Lowercase hex SHA-256 digest.
    public let edgeDigest: String

    public init(fileSize: Int64, edgeDigest: String) {
        self.fileSize = fileSize
        self.edgeDigest = edgeDigest
    }
}

extension FileFingerprint: CustomStringConvertible {
    public var description: String {
        "\(fileSize)/\(edgeDigest.prefix(12))"
    }
}
