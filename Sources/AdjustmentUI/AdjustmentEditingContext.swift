import EditorCore
import SwiftUI

/// Live readers also protect a submit that arrives before SwiftUI reconciles
/// an external reset, Undo, photo switch, or baseline update.
struct AdjustmentEditingContext: Sendable {
    var identity: @MainActor @Sendable () -> String = { "" }
    var revision: @MainActor @Sendable () -> UInt64 = { 0 }
}

private struct AdjustmentEditingContextKey: EnvironmentKey {
    static let defaultValue = AdjustmentEditingContext()
}

extension EnvironmentValues {
    var adjustmentEditingContext: AdjustmentEditingContext {
        get { self[AdjustmentEditingContextKey.self] }
        set { self[AdjustmentEditingContextKey.self] = newValue }
    }
}

extension View {
    @MainActor
    func adjustmentEditingContext(_ editor: EditorSession) -> some View {
        environment(\.adjustmentEditingContext, AdjustmentEditingContext(
            identity: { [weak editor] in editor?.photo?.id.rawValue.uuidString ?? "" },
            revision: { [weak editor] in editor?.adjustmentRevision ?? 0 }))
    }
}
