import Foundation

public enum BookmarkError: Error, Equatable, Sendable {
    case couldNotCreate(path: String, reason: String)
    /// The bookmark no longer resolves. Spec §7: show the relink flow, never
    /// guess at another volume path.
    case couldNotResolve(reason: String)
    case accessDenied(path: String)
}

extension BookmarkError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .couldNotCreate:
            return String(localized: "LumaHarbor couldn't remember access to that folder.")
        case .couldNotResolve:
            return String(localized: "LumaHarbor no longer has access to this photo folder.")
        case .accessDenied(let path):
            return "\(String(localized: "macOS denied access to")) \(path)."
        }
    }

    public var recoverySuggestion: String? {
        String(localized: "Choose the photo folder again to restore access.")
    }
}

public struct ResolvedBookmark: Sendable {
    public let url: URL
    /// macOS wants the bookmark rewritten; the caller should re-create and save.
    public let isStale: Bool
}

/// Thin wrapper over Foundation's security-scoped bookmark API.
///
/// Spec §7: this is how folder access survives a relaunch. The data stays in
/// Application Support on this Mac and is never written to the SSD or synced.
public enum SecurityScopedBookmark {
    public static func makeBookmarkData(for url: URL) throws -> Data {
        do {
            return try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw BookmarkError.couldNotCreate(
                path: url.path,
                reason: (error as NSError).localizedDescription
            )
        }
    }

    public static func resolve(_ data: Data) throws -> ResolvedBookmark {
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return ResolvedBookmark(url: url, isStale: isStale)
        } catch {
            throw BookmarkError.couldNotResolve(
                reason: (error as NSError).localizedDescription
            )
        }
    }
}
