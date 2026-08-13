import Foundation

/// Entry point wrapper.
///
/// The SwiftUI `App` type lives in this library target rather than in the
/// executable so the view models around it stay reachable from tests.
public enum LumaHarborLauncher {
    /// `App.main()` is main-actor isolated, and so is `main.swift`'s top-level
    /// code, so the hop is explicit here rather than implicit at the call site.
    @MainActor
    public static func run() {
        LumaHarborMainApp.main()
    }
}
