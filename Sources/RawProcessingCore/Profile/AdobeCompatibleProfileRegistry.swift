import Foundation

public enum RawCameraProfileCompatibility: String, Codable, Equatable, Hashable, Sendable {
    case approximate
    case preservedNotApplied
}

public struct CameraMatch: Codable, Equatable, Hashable, Sendable {
    public let make: String
    public let model: String

    public init(make: String, model: String) {
        self.make = make
        self.model = model
    }
}

public struct AdobeCompatibleProfileDescriptor: Codable, Equatable, Hashable, Sendable {
    public let sourceName: String
    public let cameraMatch: CameraMatch
    public let fallbackID: String
    public let fallbackVersion: Int
    public let compatibility: RawCameraProfileCompatibility
    public let provenance: String

    public init(
        sourceName: String,
        cameraMatch: CameraMatch,
        fallbackID: String,
        fallbackVersion: Int,
        compatibility: RawCameraProfileCompatibility,
        provenance: String
    ) {
        self.sourceName = sourceName
        self.cameraMatch = cameraMatch
        self.fallbackID = fallbackID
        self.fallbackVersion = fallbackVersion
        self.compatibility = compatibility
        self.provenance = provenance
    }
}

/// Public, renderer-independent ownership of Adobe Camera Raw profile names.
/// The registry intentionally contains only stable identifiers and provenance;
/// proprietary DCP tables and pixel transforms belong to a later calibrated
/// fallback task.
public enum AdobeCompatibleProfileRegistry {
    private static let aliases: [String: String] = [
        "adobe color": "Adobe Color",
        "adobe standard": "Adobe Standard"
    ]

    private static let referenceCameras: Set<CameraMatch> = [
        CameraMatch(make: "Sony", model: "ILCE-6400")
    ]

    public static var recognizedNames: [String] {
        ["Adobe Standard", "Adobe Color"]
    }

    public static func canonicalName(for rawName: String?) -> String? {
        guard let rawName else { return nil }
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return aliases[trimmed.lowercased()]
    }

    /// Resolves a request against the known reference camera set. A known
    /// profile on an unknown camera returns an explicit neutral descriptor so
    /// callers can keep the request while honestly reporting it was not applied.
    /// An unknown profile returns nil and must remain preserved source data.
    public static func descriptor(
        for selection: RawCameraProfileSelection,
        cameraMake: String? = nil,
        cameraModel: String? = nil
    ) -> AdobeCompatibleProfileDescriptor? {
        guard let sourceName = canonicalName(for: selection.requestedName) else { return nil }
        let normalizedMake = cameraMake.map(normalize)
        let normalizedModel = cameraModel.map(normalize)
        let match = CameraMatch(
            make: normalizedMake.map(canonicalMake) ?? "Unknown",
            model: normalizedModel ?? "Unknown"
        )

        if referenceCameras.contains(match) {
            let slug = sourceName.lowercased().replacingOccurrences(of: " ", with: "-")
            return AdobeCompatibleProfileDescriptor(
                sourceName: sourceName,
                cameraMatch: match,
                fallbackID: "\(slug)-sony-ilce-6400",
                fallbackVersion: 1,
                compatibility: .approximate,
                provenance: "LumaHarbor public fallback registry v1"
            )
        }

        return AdobeCompatibleProfileDescriptor(
            sourceName: sourceName,
            cameraMatch: match,
            fallbackID: "system-neutral-v1",
            fallbackVersion: 1,
            compatibility: .preservedNotApplied,
            provenance: "LumaHarbor system-neutral fallback v1"
        )
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "SONY", with: "Sony", options: .caseInsensitive)
    }

    private static func canonicalMake(_ value: String) -> String {
        value.caseInsensitiveCompare("Sony") == .orderedSame ? "Sony" : value
    }
}
