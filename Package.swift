// swift-tools-version: 5.9
import PackageDescription

// LumaHarbor is deliberately dependency-free: everything it needs (Core Image,
// CryptoKit, SQLite3, SwiftUI, AppKit) ships with the macOS SDK. That keeps the
// build reproducible on any Apple Silicon Mac with Xcode installed and makes the
// future iPadOS target a matter of adding a platform, not swapping libraries.
let package = Package(
    name: "LumaHarbor",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "LumaHarbor", targets: ["LumaHarbor"]),
        .library(name: "PhotoLibraryCore", targets: ["PhotoLibraryCore"]),
        .library(name: "RawProcessingCore", targets: ["RawProcessingCore"])
    ],
    targets: [
        // Decoding, adjustment pipeline, preview scheduling and export.
        // Knows nothing about folders, bookmarks or screen state.
        .target(name: "RawProcessingCore"),

        // Folder access, scanning, index, sidecars and caches.
        // Depends on RawProcessingCore only for the pure `PhotoAdjustments`
        // value type that the sidecar serialises. Never imports SwiftUI.
        .target(name: "PhotoLibraryCore", dependencies: ["RawProcessingCore"]),

        // SwiftUI + AppKit layer. Never touches CIRAWFilter directly.
        .target(name: "LumaHarborApp", dependencies: ["PhotoLibraryCore", "RawProcessingCore"]),

        // Thin launcher so the SwiftUI App type stays in a testable library target.
        .executableTarget(name: "LumaHarbor", dependencies: ["LumaHarborApp"]),

        .testTarget(name: "RawProcessingCoreTests", dependencies: ["RawProcessingCore"]),
        .testTarget(name: "PhotoLibraryCoreTests", dependencies: ["PhotoLibraryCore"]),
        .testTarget(
            name: "LumaHarborIntegrationTests",
            dependencies: ["PhotoLibraryCore", "RawProcessingCore"]
        )
    ]
)
