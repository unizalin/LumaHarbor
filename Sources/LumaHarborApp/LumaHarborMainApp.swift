import SwiftUI

/// The SwiftUI app entry point.
///
/// Named `LumaHarborMainApp` rather than `LumaHarborApp` because the module is
/// already called `LumaHarborApp`; a type of the same name would shadow it.
public struct LumaHarborMainApp: App {
    @StateObject private var libraryModel = LibraryViewModel()

    public init() {}

    public var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(libraryModel)
                .frame(minWidth: 1_100, minHeight: 700)
        }
        .commands {
            LumaHarborCommands(model: libraryModel)
        }
    }
}
