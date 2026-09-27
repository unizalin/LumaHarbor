import Foundation

/// A source Camera Raw profile request preserved independently from LumaHarbor's
/// creative `RenderingProfileSelection`. The original spelling is retained so
/// an unknown Adobe profile can be round-tripped without guessing.
public struct RawCameraProfileSelection: Codable, Equatable, Hashable, Sendable {
    public var requestedName: String?

    public init(requestedName: String? = nil) {
        self.requestedName = requestedName
    }

    public var isEmpty: Bool {
        guard let requestedName else { return true }
        return requestedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var normalizedName: String? {
        guard let requestedName else { return nil }
        let trimmed = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
