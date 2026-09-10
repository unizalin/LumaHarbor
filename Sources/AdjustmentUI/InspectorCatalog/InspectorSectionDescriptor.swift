import Foundation
import RawProcessingCore

/// One row of the shared Inspector catalog (design spec §7.1): "每個 section
/// descriptor 至少包含：stable ID、標題 key、symbol、field IDs、搜尋 tokens、是否可收藏、
/// reset 行為、適用平台與可用性診斷。"
///
/// `resetsWithDomain` doubles as the "reset behavior" the spec asks for: every
/// P2 section resets as part of its own domain, so this is currently always
/// `true`, but it is a real field (not a fabricated placeholder) -- a future
/// section that must opt out of a blanket domain reset (e.g. something that
/// needs its own confirmation) sets it to `false` and `InspectorCatalog
/// .resetting(domain:in:)` already honors it.
public struct InspectorSectionDescriptor: Identifiable, Equatable, Sendable {
    public let id: InspectorSectionID
    public let domain: PadInspectorDomain
    public let submode: PadAdjustSubmode?
    public let titleKey: String
    public let symbol: String
    public let fieldIDs: [String]
    public let searchTokens: [String]
    public let isFavoritable: Bool
    public let resetsWithDomain: Bool
    public let platforms: Set<InspectorPlatform>

    public init(
        id: InspectorSectionID,
        domain: PadInspectorDomain,
        submode: PadAdjustSubmode?,
        titleKey: String,
        symbol: String,
        fieldIDs: [String],
        searchTokens: [String],
        isFavoritable: Bool = true,
        resetsWithDomain: Bool = true,
        platforms: Set<InspectorPlatform> = [.mac, .iPad]
    ) {
        self.id = id
        self.domain = domain
        self.submode = submode
        self.titleKey = titleKey
        self.symbol = symbol
        self.fieldIDs = fieldIDs
        self.searchTokens = searchTokens
        self.isFavoritable = isFavoritable
        self.resetsWithDomain = resetsWithDomain
        self.platforms = platforms
    }

    /// Bridges `fieldIDs` to `AdjustmentKind` for the sections whose fields are
    /// plain `BasicAdjustmentPanel` sliders (`basic`, `whiteBalance`). Sections
    /// that use dotted PresetCore-style IDs (`hsl.*`, `sharpening.*`, ...) have
    /// no `AdjustmentKind` counterpart and simply bridge to an empty array --
    /// they render through their own dedicated panel instead.
    public var adjustmentKinds: [AdjustmentKind] {
        fieldIDs.compactMap { field in
            let bare = field.hasPrefix("basic.") ? String(field.dropFirst("basic.".count)) : field
            return AdjustmentKind(rawValue: bare)
        }
    }
}
