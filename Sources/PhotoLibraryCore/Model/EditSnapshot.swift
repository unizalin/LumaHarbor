import Foundation
import RawProcessingCore

/// One captured snapshot of a photo's adjustment state at a specific point in time.
/// Spec §6.6.
public struct EditSnapshot: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var adjustments: PhotoAdjustments
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        adjustments: PhotoAdjustments,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Snapshot" : name
        self.adjustments = adjustments
        self.createdAt = createdAt
    }
}
