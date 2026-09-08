import Foundation

/// Curation state attached to one indexed photo identity.
public enum PhotoFlag: String, Codable, CaseIterable, Sendable, Equatable {
    case none
    case pick
    case reject
}

/// One user-entered keyword. `normalized` is the matching key; `displayValue`
/// preserves the first spelling the user entered.
public struct PhotoKeyword: Codable, Equatable, Hashable, Sendable {
    public var normalized: String
    public var displayValue: String

    public init(normalized: String, displayValue: String) {
        self.normalized = normalized
        self.displayValue = displayValue
    }
}

public enum PhotoRatingFilter: Codable, Equatable, Sendable {
    case unrated
    case exact(Int)
}

public struct PhotoDateRange: Codable, Equatable, Sendable {
    public var start: Date?
    public var end: Date?

    public init(start: Date? = nil, end: Date? = nil) {
        self.start = start
        self.end = end
    }
}

extension PhotoKeyword {
    /// Applies the catalog's stable normalization contract.
    public static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }

    public static func make(from input: String) -> PhotoKeyword? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = normalize(trimmed)
        guard !normalized.isEmpty else { return nil }
        return PhotoKeyword(normalized: normalized, displayValue: trimmed)
    }
}
