import Foundation
import SwiftUI

@main
struct LumaHarborPadApp: App {
    // A single `PadEditorModel` — and therefore a single `EditorSession` —
    // for the app's lifetime. `PadRootView` and everything it presents must
    // keep reading this same instance rather than constructing another one.
    @StateObject private var model: PadEditorModel

    init() {
        // `PhotoDocumentStore`'s root must live under Application Support,
        // not wherever the process happens to have a writable directory —
        // but a lookup failure here must not crash the app on launch, so it
        // falls back to a temporary directory rather than force-unwrapping.
        let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        _model = StateObject(wrappedValue: PadEditorModel(applicationSupportURL: applicationSupportURL))
    }

    var body: some Scene {
        WindowGroup {
            PadRootView(model: model)
        }
    }
}
