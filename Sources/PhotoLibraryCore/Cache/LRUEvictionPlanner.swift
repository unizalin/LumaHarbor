import Foundation

public struct CacheKey: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    /// Bump when the thumbnail encoding, size policy or colour handling
    /// changes, so bytes written by an older build are never served for the new
    /// one (addendum §3.2).
    public static let thumbnailFormatVersion = 1

    /// The only persistent cache identity in the MVP.
    ///
    /// Deliberately just the photo, its size and a format version: grid
    /// thumbnails are always the neutral render of the source RAW, so there is
    /// no adjustment component to encode — and nothing here derives from
    /// `hashValue`, which is unstable across launches.
    public static func thumbnail(photoID: PhotoID, pixelDimension: Int) -> CacheKey {
        CacheKey("thumb-v\(thumbnailFormatVersion)-\(photoID)-\(pixelDimension)")
    }

    /// Safe as a filename: the components above are UUIDs and integers, but this
    /// guards against a future key that isn't.
    public var filename: String {
        rawValue
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }
}

public struct CacheEntryMetadata: Equatable, Sendable {
    public let key: CacheKey
    public let byteCount: Int64
    public var lastAccessedAt: Date

    public init(key: CacheKey, byteCount: Int64, lastAccessedAt: Date) {
        self.key = key
        self.byteCount = byteCount
        self.lastAccessedAt = lastAccessedAt
    }
}

/// Decides which cache entries to drop.
///
/// Spec §8.3: a configurable ceiling, 10 GiB by default, least-recently-used
/// first, and anything currently on screen or mid-export must survive. Kept pure
/// so the pinning rule is testable without writing gigabytes to disk.
public enum LRUEvictionPlanner {
    public static let defaultByteBudget: Int64 = 10 * 1_024 * 1_024 * 1_024 // 10 GiB

    /// Returns the keys to evict, oldest first. Never returns a pinned key, even
    /// when that means staying over budget — a stalled render is worse than a
    /// temporarily oversized cache.
    public static func keysToEvict(
        entries: [CacheEntryMetadata],
        byteBudget: Int64,
        pinned: Set<CacheKey> = []
    ) -> [CacheKey] {
        let totalBytes = entries.reduce(Int64(0)) { $0 + $1.byteCount }
        guard totalBytes > byteBudget else { return [] }

        // Tie-break on the key so the plan is deterministic when timestamps
        // collide, which they will on a fast disk.
        let candidates = entries
            .filter { !pinned.contains($0.key) }
            .sorted {
                $0.lastAccessedAt == $1.lastAccessedAt
                    ? $0.key.rawValue < $1.key.rawValue
                    : $0.lastAccessedAt < $1.lastAccessedAt
            }

        var remaining = totalBytes
        var evicted: [CacheKey] = []
        for entry in candidates where remaining > byteBudget {
            evicted.append(entry.key)
            remaining -= entry.byteCount
        }
        return evicted
    }
}
