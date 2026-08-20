// swift-tools-version: 5.9
import PackageDescription

// LumaHarbor is deliberately dependency-free: everything it needs (Core Image,
// CryptoKit, SQLite3, SwiftUI, AppKit) ships with the macOS SDK. That keeps the
// build reproducible on any Apple Silicon Mac with Xcode installed and makes the
// future iPadOS target a matter of adding a platform, not swapping libraries.
let package = Package(
    name: "LumaHarbor",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "LumaHarbor", targets: ["LumaHarbor"]),
        .library(name: "PhotoLibraryCore", targets: ["PhotoLibraryCore"]),
        .library(name: "RawProcessingCore", targets: ["RawProcessingCore"])
    ],
    targets: [
        // Holds Localizable.strings and the L10n lookup that every other
        // target routes user-facing text through. Its own target (rather
        // than living in LumaHarborApp's Resources) so RawProcessingCore and
        // PhotoLibraryCore -- which have no Resources of their own -- can
        // depend on it too without a circular dependency on the UI layer.
        .target(name: "Localization", resources: [.process("Resources")]),

        // Decoding, adjustment pipeline, preview scheduling and export.
        // Knows nothing about folders, bookmarks or screen state.
        .target(
            name: "RawProcessingCore",
            dependencies: ["Localization"],
            plugins: ["CompileMetalKernels"]
        ),

        // Compiles Sources/RawProcessingCore/Kernels/*.metal into a
        // default.metallib resource at build time -- `swift build`'s own
        // build system, unlike Xcode's, does not do this automatically.
        .plugin(
            name: "CompileMetalKernels",
            capability: .buildTool()
        ),

        // Folder access, scanning, index, sidecars and caches.
        // Depends on RawProcessingCore only for the pure `PhotoAdjustments`
        // value type that the sidecar serialises. Never imports SwiftUI.
        .target(name: "PhotoLibraryCore", dependencies: ["RawProcessingCore", "Localization"]),

        // SwiftUI + AppKit layer. Never touches CIRAWFilter directly.
        .target(
            name: "LumaHarborApp",
            dependencies: ["PhotoLibraryCore", "RawProcessingCore", "Localization"]
        ),

        // Thin launcher so the SwiftUI App type stays in a testable library target.
        .executableTarget(name: "LumaHarbor", dependencies: ["LumaHarborApp"]),

        .testTarget(name: "RawProcessingCoreTests", dependencies: ["RawProcessingCore"]),
        .testTarget(
            name: "LumaHarborAppTests",
            dependencies: ["LumaHarborApp", "PhotoLibraryCore", "RawProcessingCore", "Localization"]
        ),
        .testTarget(name: "PhotoLibraryCoreTests", dependencies: ["PhotoLibraryCore"]),
        .testTarget(
            name: "LumaHarborIntegrationTests",
            dependencies: ["PhotoLibraryCore", "RawProcessingCore"]
        )
    ]
)
