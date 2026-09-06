import Foundation
import Localization

/// What to do when an export's destination filename is already taken
/// (design spec §6.11: "同名檔處理:遞增流水號、詢問、或跳過"; roadmap
/// Phase 5 Task 5.2).
///
/// `.ask` names the "詢問" behaviour the spec lists, but this app has no
/// interactive prompt for it -- a sequential batch export has no UI seam to
/// pause mid-run and wait for a decision on one file. `.resolve(...)` below
/// reports that honestly as `.unsupportedAsk` rather than quietly behaving
/// like `.increment` or `.skip`; the Mac export UI marks it "(Not
/// Supported)" the same way an unencodable `ExportFormat` is marked, and
/// disables the export action while it's selected.
public enum ExportCollisionPolicy: String, CaseIterable, Equatable, Sendable {
    case increment
    case skip
    case ask

    public static let `default`: ExportCollisionPolicy = .increment

    public var displayName: String {
        switch self {
        case .increment: return L10n.t("Increment (DSC0001-1)")
        case .skip: return L10n.t("Skip")
        case .ask: return L10n.t("Ask Each Time")
        }
    }
}

/// What `UniqueFilenameResolver.resolve(...policy:...)` decided.
public enum CollisionResolution: Equatable, Sendable {
    /// No collision (or `.increment` found a free serial suffix): export to
    /// this URL.
    case proceed(URL)
    /// `.skip`'s target already exists: do not write anything, do not
    /// increment -- this file is intentionally left alone.
    case skip
    /// `.increment` tried every serial suffix up to the attempt limit and
    /// never found a free name.
    case incrementExhausted
    /// `.ask` was selected; see this type's own doc comment.
    case unsupportedAsk
}

extension UniqueFilenameResolver {
    /// Policy-aware collision resolution. Does not replace or change the
    /// behaviour of the existing `resolve(baseName:fileExtension:in:
    /// maximumAttempts:exists:)` above (still `.increment`'s own
    /// implementation, reused here) -- this only adds the `.skip`/`.ask`
    /// branches around it.
    public static func resolve(
        baseName: String,
        fileExtension: String,
        in directory: URL,
        policy: ExportCollisionPolicy,
        maximumAttempts: Int = maximumAttempts,
        exists: (URL) -> Bool
    ) -> CollisionResolution {
        switch policy {
        case .ask:
            return .unsupportedAsk
        case .increment:
            guard let url = resolve(
                baseName: baseName,
                fileExtension: fileExtension,
                in: directory,
                maximumAttempts: maximumAttempts,
                exists: exists
            ) else {
                return .incrementExhausted
            }
            return .proceed(url)
        case .skip:
            let candidate = directory.appendingPathComponent(sanitize(baseName)).appendingPathExtension(fileExtension)
            return exists(candidate) ? .skip : .proceed(candidate)
        }
    }

    public static func resolve(
        baseName: String,
        fileExtension: String,
        in directory: URL,
        policy: ExportCollisionPolicy,
        fileManager: FileManager = .default
    ) -> CollisionResolution {
        resolve(baseName: baseName, fileExtension: fileExtension, in: directory, policy: policy) { url in
            fileManager.fileExists(atPath: url.path)
        }
    }
}
