import Foundation
import RawProcessingCore

/// A known Adobe Camera Raw profile name and its current LumaHarbor status.
///
/// The registry deliberately describes the compatibility claim rather than
/// pretending that a profile name is itself a portable rendering algorithm.
/// A descriptor with no fallback keeps the source name preserved while the
/// renderer stays on its neutral baseline.
public struct AdobeProfileDescriptor: Equatable, Hashable, Sendable {
    public let name: String
    public let level: XMPCompatibilityLevel
    public let fallbackProfileID: String?

    public init(name: String, level: XMPCompatibilityLevel, fallbackProfileID: String? = nil) {
        self.name = name
        self.level = level
        self.fallbackProfileID = fallbackProfileID
    }
}

/// Versioned Adobe profile recognition used by XMP import and capability
/// summaries. Proprietary DCP, digest, and table data are intentionally not
/// embedded here.
public enum AdobeProfileRegistry {
    public static var recognizedNames: Set<String> {
        Set(AdobeCompatibleProfileRegistry.recognizedNames)
    }

    public static func descriptor(for rawName: String) -> AdobeProfileDescriptor? {
        guard let canonical = AdobeCompatibleProfileRegistry.canonicalName(for: rawName) else { return nil }
        // PresetCore keeps the legacy capability shape as an adapter. The
        // renderer-owned descriptor and any future fallback remain in
        // RawProcessingCore.
        return AdobeProfileDescriptor(name: canonical, level: .preserved)
    }
}
