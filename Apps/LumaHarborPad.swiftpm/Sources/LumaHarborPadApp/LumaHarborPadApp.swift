import Foundation
import SwiftUI

@main
struct LumaHarborPadApp: App {
    // One `PadAppServices` for the app's lifetime, built here — never from
    // `body`, which re-evaluates far more often than the app actually
    // launches and would silently stand up a second SQLite connection and a
    // second `PhotoDocumentStore` root lock contender. `library`/`editor`
    // are the exact instances `services` itself holds; they're re-declared
    // as `@StateObject`s here (rather than read through `services` in every
    // child view) purely so SwiftUI's observation machinery attaches to
    // them the same way it already does for every other `@StateObject` in
    // this app.
    let services: PadAppServices
    @StateObject private var library: PadLibraryModel
    @StateObject private var editor: PadEditorModel

    init() {
        // `PadAppServices`'s root must live under Application Support, not
        // wherever the process happens to have a writable directory — but a
        // lookup failure here must not crash the app on launch, so it falls
        // back to a temporary directory rather than force-unwrapping.
        let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory

        let services: PadAppServices
        do {
            services = try PadAppServices(applicationSupportURL: applicationSupportURL)
        } catch {
            // The primary location failed (for example, the on-disk index
            // couldn't be opened) — fall back to a fresh temporary root
            // rather than crashing on launch, the same philosophy as the
            // URL lookup above. If even a fresh temporary directory can't
            // back this, there is genuinely no writable storage available
            // at all, and nothing short of a crash can recover from that.
            services = try! PadAppServices(
                applicationSupportURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("LumaHarborPadFallback-\(UUID().uuidString)", isDirectory: true)
            )
        }
        self.services = services
        _library = StateObject(wrappedValue: services.library)
        _editor = StateObject(wrappedValue: services.editor)
    }

    var body: some Scene {
        WindowGroup {
            PadRootView(services: services, editor: editor, library: library)
        }
    }
}
