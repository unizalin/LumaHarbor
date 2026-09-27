import Localization
import RawProcessingCore

/// A privacy-safe, device-neutral row for the Info panel's RAW provenance
/// section. Values are either a localization key or a canonical profile name;
/// decoder detail strings and source paths never cross this boundary.
public struct RawRenderDiagnosticRow: Identifiable, Equatable, Sendable {
    public let identifier: String
    public let labelKey: String
    public let valueKey: String?
    public let literalValue: String?

    public var id: String { identifier }

    public init(
        identifier: String,
        labelKey: String,
        valueKey: String? = nil,
        literalValue: String? = nil
    ) {
        self.identifier = identifier
        self.labelKey = labelKey
        self.valueKey = valueKey
        self.literalValue = literalValue
    }

    public var displayValue: String {
        if let literalValue { return literalValue }
        guard let valueKey else { return "" }
        return L10n.t(valueKey)
    }
}

/// Maps the resolved render recipe to the exact fields shown on Mac and iPad.
/// Keeping this as a pure presenter prevents the two surfaces from drifting in
/// wording or from accidentally exposing private decoder provenance.
public enum RawRenderDiagnosticsPresenter {
    public static func rows(for recipe: ResolvedRawRenderRecipe?) -> [RawRenderDiagnosticRow] {
        guard let recipe else { return [] }

        let modeKey = recipe.effectivePolicy == .native
            ? "LumaHarbor Native"
            : "Lightroom-compatible v1"
        let whiteBalanceKey = recipe.whiteBalance.temperatureOffsetKelvin == 0
            && recipe.whiteBalance.tintOffset == 0
            ? "As Shot"
            : "Adjusted"

        let requestedProfile = recipe.cameraProfile.requestedName
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let resolvedFallbackKey: String
        switch recipe.cameraProfile.compatibility {
        case .preservedNotApplied:
            resolvedFallbackKey = "Profile Preserved, Not Applied"
        case .approximate:
            resolvedFallbackKey = "Approximate fallback"
        case nil:
            resolvedFallbackKey = "None"
        }

        let decoderFallback = recipe.diagnostics.contains {
            $0.code == .rawDecoderVersionFallback || $0.code == .rawOptionUnavailable
        }
        let metadataFallback = recipe.diagnostics.contains { $0.code == .metadataFallback }

        return [
            RawRenderDiagnosticRow(
                identifier: "rawRender.mode",
                labelKey: "Rendering Mode",
                valueKey: modeKey
            ),
            RawRenderDiagnosticRow(
                identifier: "rawRender.asShotWhiteBalance",
                labelKey: "White Balance",
                valueKey: whiteBalanceKey
            ),
            RawRenderDiagnosticRow(
                identifier: "rawRender.requestedProfile",
                labelKey: "Requested Camera Profile",
                valueKey: requestedProfile == nil ? "None" : nil,
                literalValue: requestedProfile
            ),
            RawRenderDiagnosticRow(
                identifier: "rawRender.resolvedFallback",
                labelKey: "Resolved Profile",
                valueKey: resolvedFallbackKey
            ),
            RawRenderDiagnosticRow(
                identifier: "rawRender.decoderFallback",
                labelKey: "Decoder",
                valueKey: decoderFallback ? "Fallback" : "None"
            ),
            RawRenderDiagnosticRow(
                identifier: "rawRender.metadataFallback",
                labelKey: "Metadata",
                valueKey: metadataFallback ? "Fallback" : "None"
            ),
        ]
    }
}
