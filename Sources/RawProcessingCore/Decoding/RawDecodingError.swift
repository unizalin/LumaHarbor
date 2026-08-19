import Foundation
import Localization

/// Failures the UI has to tell apart.
///
/// Spec §10 gives each of these a distinct user-facing outcome, so they stay
/// separate cases rather than one `decodeFailed(String)`.
public enum RawDecodingError: Error, Equatable, Sendable {
    /// The file is gone or the volume is not mounted. Recoverable by reconnecting.
    case fileUnavailable(path: String)
    /// ImageIO can read the container but no RAW decoder claims it.
    case unsupportedFormat(path: String)
    /// The bytes are unreadable. Spec §10: mark this one photo, keep scanning.
    case corruptedFile(path: String)
    /// The decoder produced no image for a reason it could not classify.
    case decodeFailed(path: String, reason: String)
    case cancelled
}

extension RawDecodingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .fileUnavailable(let path):
            return "\(L10n.t("The original file is not available at")) \(path)."
        case .unsupportedFormat:
            return L10n.t("This camera's RAW format isn't supported yet.")
        case .corruptedFile:
            return L10n.t("This RAW file appears to be damaged.")
        case .decodeFailed(_, let reason):
            return "\(L10n.t("The RAW file couldn't be decoded.")) \(reason)"
        case .cancelled:
            return L10n.t("The operation was cancelled.")
        }
    }

    /// Spec §10: every user-actionable error carries its next step.
    public var recoverySuggestion: String? {
        switch self {
        case .fileUnavailable:
            return L10n.t("Reconnect the drive holding this photo, then try again.")
        case .unsupportedFormat:
            return L10n.t("Keep the file in your library — support may arrive in a future macOS release.")
        case .corruptedFile:
            return L10n.t("Try re-copying this file from the memory card.")
        case .decodeFailed:
            return L10n.t("Try again, or re-copy this file from the memory card.")
        case .cancelled:
            return nil
        }
    }
}
