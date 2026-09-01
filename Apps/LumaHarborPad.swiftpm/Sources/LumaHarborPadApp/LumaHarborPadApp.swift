import Foundation
import EditorCore
import Localization
import SwiftUI

@main
struct LumaHarborPadApp: App {
    // One `PadAppServices` for the app's lifetime, built here — never from
    // `body`, which re-evaluates far more often than the app actually
    // launches and would silently stand up a second SQLite connection and a
    // second `PhotoDocumentStore` root lock contender. Bootstrap is an
    // explicit state so a storage failure can render a readable startup
    // screen instead of force-crashing before SwiftUI draws anything.
    let bootstrapState: PadAppBootstrapState

    init() {
        bootstrapState = Self.makeBootstrapState()
    }

    var body: some Scene {
        WindowGroup {
            switch bootstrapState {
            case .ready(let services):
                PadRootView(services: services, editor: services.editor, library: services.library)
            case .failed(let alert):
                PadStartupFailureView(alert: alert)
            }
        }
    }

    private static func makeBootstrapState() -> PadAppBootstrapState {
        // `PadAppServices`'s root must live under Application Support, not
        // wherever the process happens to have a writable directory — but a
        // lookup failure here must not crash the app on launch, so it falls
        // back to a temporary directory.
        let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory

        do {
            return .ready(try PadAppServices(applicationSupportURL: applicationSupportURL))
        } catch {
            // The primary location failed (for example, the on-disk index
            // couldn't be opened) — fall back to a fresh temporary root
            // rather than crashing on launch. If even a fresh temporary
            // directory can't back this, render a readable failure screen.
        }

        let fallbackURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumaHarborPadFallback-\(UUID().uuidString)", isDirectory: true)
        do {
            return .ready(try PadAppServices(applicationSupportURL: fallbackURL))
        } catch {
            return .failed(EditorAlert(
                title: L10n.t("Couldn't start LumaHarbor"),
                message: L10n.t("LumaHarbor couldn't open local storage."),
                nextStep: L10n.t("Free up space on your startup disk, then reopen LumaHarbor.")
            ))
        }
    }
}

enum PadAppBootstrapState {
    case ready(PadAppServices)
    case failed(EditorAlert)
}

struct PadStartupFailureView: View {
    let alert: EditorAlert

    var body: some View {
        ContentUnavailableView {
            Label(alert.title, systemImage: "exclamationmark.triangle")
        } description: {
            Text([alert.message, alert.nextStep].compactMap { $0 }.joined(separator: "\n\n"))
        }
    }
}
