import Foundation

/// Which platform's Inspector a section is reachable from (design spec §7.1
/// "適用平台"). Every P2-era section is available on both -- this exists so a
/// future platform-specific section (or a temporarily-disabled one) has
/// somewhere to declare that without inventing a parallel list.
public enum InspectorPlatform: String, CaseIterable, Codable, Sendable {
    case mac
    case iPad
}
