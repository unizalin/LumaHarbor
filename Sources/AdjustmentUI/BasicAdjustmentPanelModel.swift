import Foundation
import RawProcessingCore

public enum BasicAdjustmentPanelModel {
    public static let rows: [AdjustmentDefinition] = AdjustmentCatalog.ordered

    public static func formatted(_ value: Double, fractionDigits: Int) -> String {
        let text = String(format: "%.*f", fractionDigits, value)
        return value > 0 ? "+\(text)" : text
    }
}
