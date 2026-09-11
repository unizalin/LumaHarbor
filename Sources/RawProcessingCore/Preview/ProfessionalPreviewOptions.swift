import Foundation

/// Color spaces supported for soft proofing.
public enum SoftProofProfile: String, CaseIterable, Codable, Sendable {
    case sRGB = "sRGB"
    case displayP3 = "Display P3"
    case adobeRGB = "Adobe RGB"
}

/// Options controlling professional review overlays and soft-proofing.
/// Only affects preview rendering; never baked into export files or written to sidecars.
public struct ProfessionalPreviewOptions: Equatable, Sendable {
    public var showHighlightClipping: Bool
    public var showShadowClipping: Bool
    public var showGamutWarning: Bool
    public var softProofProfile: SoftProofProfile?

    public init(
        showHighlightClipping: Bool = false,
        showShadowClipping: Bool = false,
        showGamutWarning: Bool = false,
        softProofProfile: SoftProofProfile? = nil
    ) {
        self.showHighlightClipping = showHighlightClipping
        self.showShadowClipping = showShadowClipping
        self.showGamutWarning = showGamutWarning
        self.softProofProfile = softProofProfile
    }

    public var isActive: Bool {
        showHighlightClipping || showShadowClipping || showGamutWarning || softProofProfile != nil
    }

    public static let standard = ProfessionalPreviewOptions()
}
