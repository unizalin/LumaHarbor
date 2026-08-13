import LumaHarborApp

/// The executable owns the process entry point; the SwiftUI scene remains in
/// `LumaHarborApp` so its view models and composition stay testable.
@main
struct LumaHarborEntryPoint {
    @MainActor
    static func main() {
        LumaHarborLauncher.run()
    }
}
