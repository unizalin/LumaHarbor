import Foundation
import Localization

/// Design spec §6.11: "浮水印:文字、位置、不透明度、大小" (roadmap Phase 5
/// Task 5.2). Pure value type -- `WatermarkRenderer` is what actually draws
/// it onto a `CIImage`.
public struct Watermark: Equatable, Sendable {
    public enum Position: String, CaseIterable, Equatable, Sendable {
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight
        case center

        public var displayName: String {
            switch self {
            case .topLeft: return L10n.t("Top Left")
            case .topRight: return L10n.t("Top Right")
            case .bottomLeft: return L10n.t("Bottom Left")
            case .bottomRight: return L10n.t("Bottom Right")
            case .center: return L10n.t("Center")
            }
        }
    }

    public var text: String
    public var position: Position
    /// 0 (invisible) ... 1 (fully opaque). Out-of-range inputs are clamped
    /// rather than left to silently misbehave at the compositing filter.
    public var opacity: Double
    /// Fraction of the output image's shorter edge used as the watermark
    /// text's font size (e.g. `0.04` = 4%). Clamped to a small positive
    /// floor so a mistakenly-zero value never renders literally invisible
    /// text that still costs a render pass.
    public var sizeFraction: Double

    public init(
        text: String,
        position: Position = .bottomRight,
        opacity: Double = 0.6,
        sizeFraction: Double = 0.04
    ) {
        self.text = text
        self.position = position
        self.opacity = min(max(opacity, 0), 1)
        self.sizeFraction = min(max(sizeFraction, 0.005), 1)
    }
}
