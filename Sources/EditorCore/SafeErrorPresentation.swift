import Foundation
import Localization
import PhotoLibraryCore
import RawProcessingCore

/// Maps an arbitrary thrown error to fixed, localized, safe-for-display
/// text, and builds an `EditorAlert` from it.
///
/// Several error types this app throws carry a file's absolute path
/// directly inside their own `errorDescription` — `RawDecodingError
/// .fileUnavailable`, `FingerprintError.fileUnavailable`/`.readFailed`,
/// `BookmarkError.accessDenied`, `SidecarError.notWritable`/
/// `.libraryUnavailable`, `AtomicWriteError`'s path-carrying cases, and any
/// bare `NSError` from `FileManager`. Spec §9 requires user-facing text to
/// never include one. Every `message(for:)` branch below is a fixed,
/// known-safe string; `message(for:)` never forwards `error
/// .localizedDescription` or `errorDescription` for *any* error, known or
/// not — that is what makes it safe to use for an error this has never seen
/// before, not just the cases it recognizes by name.
///
/// `recoverySuggestion`, by contrast, genuinely is path-free for every case
/// of every error type this app defines (verified by reading each one) —
/// so `nextStep(for:)` reuses it directly for known families rather than
/// hand-duplicating the same fixed text a second time.
///
/// `EditorSession` routes every alert it builds from a caught error through
/// this — never by reading `error.errorDescription` itself — so this is the
/// single place a new unsafe error type needs to be special-cased, rather
/// than something every call site has to remember on its own.
public enum SafeErrorPresentation {
    public static func alert(title: String, for error: Error) -> EditorAlert {
        EditorAlert(title: title, message: message(for: error), nextStep: nextStep(for: error))
    }

    public static func message(for error: Error) -> String {
        if error is CancellationError {
            return L10n.t("The operation was cancelled.")
        }
        if let error = error as? RawDecodingError {
            return message(for: error)
        }
        if let error = error as? FingerprintError {
            return message(for: error)
        }
        if let error = error as? BookmarkError {
            return message(for: error)
        }
        if let error = error as? PhotoDocumentError {
            return message(for: error)
        }
        if let error = error as? AtomicWriteError {
            return message(for: error)
        }
        if let error = error as? SidecarError {
            return message(for: error)
        }
        if let error = error as? LibraryError {
            return message(for: error)
        }
        return L10n.t("Something went wrong.")
    }

    public static func nextStep(for error: Error) -> String? {
        if error is CancellationError {
            return nil
        }
        if let error = error as? PhotoDocumentError {
            // Not `LocalizedError` — handled explicitly below.
            return nextStep(for: error)
        }
        guard isFamilyWithVerifiedSafeRecoverySuggestion(error) else { return nil }
        return (error as? LocalizedError)?.recoverySuggestion
    }

    /// Every case of every type listed here has been read end to end: none
    /// of their `recoverySuggestion` implementations interpolate a path or
    /// any other error's raw text. Adding a new error family here requires
    /// re-verifying that invariant for it, the same way — never assume it.
    private static func isFamilyWithVerifiedSafeRecoverySuggestion(_ error: Error) -> Bool {
        error is RawDecodingError
            || error is FingerprintError
            || error is BookmarkError
            || error is AtomicWriteError
            || error is SidecarError
            || error is LibraryError
    }

    // MARK: - RawDecodingError

    private static func message(for error: RawDecodingError) -> String {
        switch error {
        case .fileUnavailable:
            // The only case here whose own `errorDescription` embeds the
            // absolute path; every other case's real message is already
            // path-free and reused as-is below.
            return L10n.t("The original file isn't available right now.")
        case .unsupportedFormat:
            return L10n.t("This camera's RAW format isn't supported yet.")
        case .corruptedFile:
            return L10n.t("This RAW file appears to be damaged.")
        case .decodeFailed:
            return L10n.t("The RAW file couldn't be decoded.")
        case .cancelled:
            return L10n.t("The operation was cancelled.")
        }
    }

    // MARK: - FingerprintError

    private static func message(for error: FingerprintError) -> String {
        switch error {
        case .fileUnavailable:
            return L10n.t("The original file isn't available right now.")
        case .readFailed:
            // `reason` is a system error's own description and is not
            // trusted to be path-free, so it is never surfaced here.
            return L10n.t("Couldn't read the file.")
        }
    }

    // MARK: - BookmarkError

    private static func message(for error: BookmarkError) -> String {
        switch error {
        case .couldNotCreate:
            return L10n.t("LumaHarbor couldn't remember access to that folder.")
        case .couldNotResolve:
            return L10n.t("LumaHarbor no longer has access to this photo folder.")
        case .accessDenied:
            return L10n.t("LumaHarbor no longer has access to this file.")
        }
    }

    // MARK: - AtomicWriteError

    private static func message(for error: AtomicWriteError) -> String {
        switch error {
        case .destinationNotWritable:
            return L10n.t("This drive is read-only, so edits can't be saved next to your photos.")
        case .volumeUnavailable:
            return L10n.t("The drive holding this library isn't available.")
        case .insufficientDiskSpace:
            return L10n.t("There isn't enough free space to save your edits.")
        case .writeFailed:
            return L10n.t("Your edits couldn't be saved.")
        }
    }

    // MARK: - SidecarError

    private static func message(for error: SidecarError) -> String {
        switch error {
        case .unsupportedSchemaVersion:
            return L10n.t("These edits were saved by a newer version of LumaHarbor")
        case .corruptSidecar:
            return L10n.t("The saved edits for this photo are damaged.")
        case .corruptManifest:
            return L10n.t("This library's index file is damaged.")
        case .libraryUnavailable:
            return L10n.t("The drive holding this library isn't available.")
        case .notWritable:
            return L10n.t("This drive is read-only, so edits can't be saved.")
        case .write(let writeError):
            return message(for: writeError)
        }
    }

    // MARK: - LibraryError

    private static func message(for error: LibraryError) -> String {
        switch error {
        case .bookmark(let bookmarkError):
            return message(for: bookmarkError)
        case .sidecar(let sidecarError):
            return message(for: sidecarError)
        case .offline:
            return L10n.t("The drive holding this library isn't connected.")
        case .notFound:
            return L10n.t("That photo folder is no longer in your library list.")
        case .indexUnavailable:
            return L10n.t("The local index is unavailable.")
        case .resetRefusedWhileScanning:
            return L10n.t("The local index can't be reset while a scan is in progress.")
        case .resetFailed:
            return L10n.t("The local index couldn't be reset.")
        }
    }

    // MARK: - PhotoDocumentError

    private static func message(for error: PhotoDocumentError) -> String {
        switch error {
        case .copyVerificationFailed:
            return L10n.t("The copy didn't match the original file, so nothing was saved.")
        case .sourceModifiedDuringImport:
            return L10n.t("The original file changed while LumaHarbor was copying it, so nothing was saved.")
        case .importInProgress:
            return L10n.t("LumaHarbor is already importing or cleaning up another photo.")
        case .documentNotFound:
            return L10n.t("LumaHarbor couldn't find this photo's saved document.")
        }
    }

    private static func nextStep(for error: PhotoDocumentError) -> String? {
        switch error {
        case .copyVerificationFailed:
            return L10n.t("Try copying this photo again.")
        case .sourceModifiedDuringImport:
            return L10n.t("Make sure the file isn't being modified, then try again.")
        case .importInProgress:
            return L10n.t("Wait a moment, then try again.")
        case .documentNotFound:
            return L10n.t("Choose the file again from Files.")
        }
    }
}
