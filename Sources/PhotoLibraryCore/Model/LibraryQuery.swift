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

    public init(scope: LibraryScope, filenameSearch: String? = nil, sort: PhotoSort) {
        self.scope = scope
        self.filenameSearch = filenameSearch
        self.sort = sort
    }
}

/// Opaque keyset position. Carries only the sort key actually in play for the
/// query plus the tie-breaking `PhotoID` — never a URL or absolute path, so a
/// stashed cursor can't be used to infer filesystem layout.
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
}
