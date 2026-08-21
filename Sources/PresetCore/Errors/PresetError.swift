import Foundation
import Localization

/// Every error the Preset/XMP compatibility layer can surface.
///
/// Spec §11: at least these categories, and every user-visible error must be
/// able to say what happened, what wasn't changed, and what to do next. This
/// type stays a plain, `Equatable` value (no associated `Error` payloads other
/// than primitives) so tests can assert on it directly with `==`.
public enum PresetError: Error, Equatable, Sendable {
    case invalidName
    case invalidGroupPath
    case unsupportedSchemaVersion(found: Int, supported: Int)
    case unsupportedDocumentKind(String)
    case malformedXML(String)
    case malformedJSON(String)
    case unsafeXMLConstruct(String)
    case documentTooLarge(limitBytes: Int)
    case documentTooDeep(limit: Int)
    case tooManyProperties(limit: Int)
    case valueTooLarge(limitBytes: Int)
    case unknownProcessVersion(String)
    case noApplicableAdjustments
    case readOnlyDestination(String)
    case destinationUnavailable(String)
    case identityConflict(UUID)
    case partialBatchFailure(succeeded: Int, failed: Int)
    case reverseMappingUnavailable(String)
}

extension PresetError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidName:
            return L10n.t("This preset needs a name, and names can't be over 120 characters.")
        case .invalidGroupPath:
            return L10n.t("This group path isn't valid: each level needs a name and there's a limit of 8 levels.")
        case .unsupportedSchemaVersion(let found, let supported):
            return "\(L10n.t("This preset was saved by a newer version of LumaHarbor")) "
                + "(format \(found); this version reads up to \(supported))."
        case .unsupportedDocumentKind(let kind):
            return "\(L10n.t("LumaHarbor doesn't recognise this file as a develop preset or camera raw settings document.")) (\(kind))"
        case .malformedXML:
            return L10n.t("This XMP file couldn't be read; its XML is malformed.")
        case .malformedJSON:
            return L10n.t("This preset file couldn't be read; its JSON is malformed.")
        case .unsafeXMLConstruct(let construct):
            return "\(L10n.t("This XMP file was rejected because it contains a disallowed construct.")) (\(construct))"
        case .documentTooLarge(let limit):
            return "\(L10n.t("This file is larger than LumaHarbor allows for a preset or XMP document.")) (\(limit) bytes)"
        case .documentTooDeep(let limit):
            return "\(L10n.t("This XMP file is nested deeper than LumaHarbor allows.")) (\(limit))"
        case .tooManyProperties(let limit):
            return "\(L10n.t("This XMP file has more properties than LumaHarbor allows.")) (\(limit))"
        case .valueTooLarge(let limit):
            return "\(L10n.t("A value in this XMP file is larger than LumaHarbor allows.")) (\(limit) bytes)"
        case .unknownProcessVersion(let version):
            return "\(L10n.t("LumaHarbor doesn't recognise this Camera Raw process version.")) (\(version))"
        case .noApplicableAdjustments:
            return L10n.t("This preset has no adjustments LumaHarbor can apply yet.")
        case .readOnlyDestination:
            return L10n.t("This drive is read-only, so LumaHarbor can't save the preset there.")
        case .destinationUnavailable:
            return L10n.t("The destination for this preset isn't available right now.")
        case .identityConflict:
            return L10n.t("A preset with this identity already exists.")
        case .partialBatchFailure(let succeeded, let failed):
            return "\(L10n.t("Some files in this batch couldn't be imported.")) (\(succeeded)/\(succeeded + failed))"
        case .reverseMappingUnavailable(let field):
            return "\(L10n.t("This adjustment has no XMP equivalent to export.")) (\(field))"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .invalidName, .invalidGroupPath:
            return L10n.t("Choose a shorter name or path, then try again.")
        case .unsupportedSchemaVersion:
            return L10n.t("Update LumaHarbor, or edit this preset on the device that wrote it.")
        case .unsupportedDocumentKind, .malformedXML, .malformedJSON, .unsafeXMLConstruct,
             .documentTooLarge, .documentTooDeep, .tooManyProperties, .valueTooLarge:
            return L10n.t("Nothing was imported. Choose a different file, or fix and re-export it, then try again.")
        case .unknownProcessVersion:
            return L10n.t("The preset was kept as unsupported data; no adjustments were applied.")
        case .noApplicableAdjustments:
            return L10n.t("You can still save it to keep the original data, but it won't change your photo.")
        case .readOnlyDestination:
            return L10n.t("Unlock the drive or choose a different scope, then retry.")
        case .destinationUnavailable:
            return L10n.t("Reconnect the drive or choose a different scope, then retry.")
        case .identityConflict:
            return L10n.t("Choose to replace it, keep both, or cancel.")
        case .partialBatchFailure:
            return L10n.t("Review the per-file results and retry the ones that failed.")
        case .reverseMappingUnavailable:
            return L10n.t("You can still export; this adjustment just won't round-trip back into Lightroom.")
        }
    }
}
