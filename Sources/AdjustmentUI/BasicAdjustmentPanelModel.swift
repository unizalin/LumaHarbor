import Foundation
import Localization
import RawProcessingCore

public enum BasicAdjustmentPanelModel {
    public static let rows: [AdjustmentDefinition] = AdjustmentCatalog.ordered

    public static func formatted(_ value: Double, fractionDigits: Int) -> String {
        let text = String(format: "%.*f", fractionDigits, value)
        return value > 0 ? "+\(text)" : text
    }

    public static func unavailableWhiteBalanceMessage(
        for capability: WhiteBalancePresentation.Capability
    ) -> String {
        switch capability {
        case .loading:
            L10n.t("White balance baseline is still loading.")
        case .invalid:
            L10n.t("White balance baseline is invalid; Kelvin adjustment is unavailable.")
        case .unavailable, .valid:
            L10n.t("White balance is unavailable for this photo.")
        }
    }
}
