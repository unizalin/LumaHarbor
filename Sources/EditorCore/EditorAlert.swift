import Foundation

public struct EditorAlert: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var message: String
    public var nextStep: String?

    public init(id: UUID = UUID(), title: String, message: String, nextStep: String? = nil) {
        self.id = id
        self.title = title
        self.message = message
        self.nextStep = nextStep
    }
}
