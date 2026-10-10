import EditorCore
import SwiftUI

/// Live identity and revision readers prevent a native field from submitting
/// a draft after a reset, undo, or photo switch that SwiftUI has not rendered.
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
            revision: { [weak editor] in editor?.adjustmentRevision ?? 0 }
        ))
    }
}
