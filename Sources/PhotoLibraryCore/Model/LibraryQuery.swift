import Foundation

/// What subset of the multi-source index a page request draws from.
///
/// `.folder` includes the named directory and every descendant beneath it;
/// an empty `relativePath` means the source root. `.appStorage` and
/// `.recentlyEdited` cut across libraries rather than naming one.
public enum LibraryScope: Sendable, Equatable {
    case all
    case source(LibraryID)
    case folder(libraryID: LibraryID, relativePath: String)
    case appStorage
    case recentlyEdited
}

public enum PhotoSort: Sendable, Equatable {
    case captureDateDescending
    case captureDateAscending
    case filenameAscending
    case filenameDescending
}

public struct LibraryQuery: Sendable, Equatable {
    public var scope: LibraryScope
    public var filenameSearch: String?
    public var sort: PhotoSort
    public var rating: PhotoRatingFilter?
    public var flag: PhotoFlag?
    public var hasEdits: Bool?
    public var format: String?
    public var camera: String?
    public var lens: String?
    public var captureDate: PhotoDateRange?
    public var keyword: String?

    public init(
        scope: LibraryScope,
        filenameSearch: String? = nil,
        sort: PhotoSort,
        rating: PhotoRatingFilter? = nil,
        flag: PhotoFlag? = nil,
        hasEdits: Bool? = nil,
        format: String? = nil,
        camera: String? = nil,
        lens: String? = nil,
        captureDate: PhotoDateRange? = nil,
        keyword: String? = nil
    ) {
        self.scope = scope
        self.filenameSearch = filenameSearch
        self.sort = sort
        self.rating = rating
        self.flag = flag
        self.hasEdits = hasEdits
        self.format = format
        self.camera = camera
        self.lens = lens
        self.captureDate = captureDate
        self.keyword = keyword
    }

    /// Stable, human-independent identity for query coordination and stale
    /// result rejection. The value is intentionally opaque to UI callers.
    public var fingerprint: String {
        String(describing: self)
    }
}

/// Opaque keyset position. Carries only the sort key actually in play for the
/// query plus the tie-breaking `PhotoID` — never a URL or absolute path, so a
/// stashed cursor can't be used to infer filesystem layout.
///
/// A cursor is only valid when passed back into the same `LibraryQuery`
/// (scope, filename search, and sort direction) that produced it.
/// `page(matching:after:limit:)` validates the cursor's key *shape* against
/// the requested sort — e.g. rejecting a filename cursor reused against a
/// capture-date sort — via `LibraryQueryError.invalidCursor`. It cannot,
/// however, detect a cursor whose shape is compatible but whose position is
/// semantically stale, such as a capture-date-ascending cursor replayed
/// against capture-date-descending, or against a query whose scope or
/// filename search changed since the cursor was minted. Callers are
/// responsible for scoping a cursor to the exact query that produced it;
/// binding cursor identity to a full query fingerprint is unscoped future
/// work, not part of this contract.
public struct PhotoPageCursor: Sendable, Equatable {
    public var dateKey: Date?
    public var filenameKey: String?
    public var photoID: PhotoID

    public init(dateKey: Date? = nil, filenameKey: String? = nil, photoID: PhotoID) {
        self.dateKey = dateKey
        self.filenameKey = filenameKey
        self.photoID = photoID
    }
}

public struct PhotoPage: Sendable, Equatable {
    public var photos: [PhotoAsset]
    public var nextCursor: PhotoPageCursor?

    public init(photos: [PhotoAsset], nextCursor: PhotoPageCursor?) {
        self.photos = photos
        self.nextCursor = nextCursor
    }
}

/// One lazily-expanded node in the folder sidebar. `childCount` is the number
/// of indexed photos in this directory or any of its descendants.
public struct LibraryDirectoryNode: Sendable, Equatable, Identifiable {
    public var id: String { "\(libraryID.description)/\(relativePath)" }
    public var libraryID: LibraryID
    public var relativePath: String
    public var displayName: String
    public var childCount: Int

    public init(libraryID: LibraryID, relativePath: String, displayName: String, childCount: Int) {
        self.libraryID = libraryID
        self.relativePath = relativePath
        self.displayName = displayName
        self.childCount = childCount
    }
}

public enum LibraryQueryError: Error, Equatable, Sendable {
    /// Production callers may only request `1...200` rows per page.
    case invalidLimit(Int)
    /// The supplied cursor doesn't carry the key the requested sort needs
    /// (e.g. a filename cursor reused against a capture-date sort).
    case invalidCursor
    /// `setEditState` was asked to record `hasEdits: true` with no edit
    /// date. Every non-neutral edit needs a timestamp for `.recentlyEdited`
    /// to sort by, so this shape is rejected rather than silently written
    /// as a contradictory row.
    case missingEditDate
    case invalidRating(Int)
    /// Empty or whitespace-only keyword input is invalid rather than silently
    /// turning into a query or mutation that matches every photo.
    case invalidKeyword
}
