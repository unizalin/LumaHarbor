import Foundation

/// Portable rating/flag/keyword record carried by `PhotoSidecar` (spec §6.1).
/// This is the authority; `PhotoIndexStore`'s `rating`/`flag`/`photo_keyword`
/// columns are only a rebuildable SQLite projection of it.
public struct PhotoCuration: Codable, Equatable, Sendable {
    public var rating: Int
    public var flag: PhotoFlag
    /// Deduplicated by `normalized`, sorted by `normalized` so an unchanged
    /// curation always re-encodes to the same bytes (matches the sidecar's
    /// own stable-encoding goal, spec §8.2).
    public var keywords: [PhotoKeyword]

    public init(rating: Int = 0, flag: PhotoFlag = .none, keywords: [PhotoKeyword] = []) {
        self.rating = min(max(rating, 0), 5)
        self.flag = flag
        var seen = Set<String>()
        self.keywords = keywords
            .filter { seen.insert($0.normalized).inserted }
            .sorted { $0.normalized < $1.normalized }
    }

    public static let neutral = PhotoCuration()

    public var isNeutral: Bool { self == .neutral }
}
