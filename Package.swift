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
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .executable(name: "LumaHarbor", targets: ["LumaHarbor"]),
        .library(name: "PhotoLibraryCore", targets: ["PhotoLibraryCore"]),
        // RawProcessingCore deliberately remains an internal target. It
        // carries CompileMetalKernels; exposing it as another top-level
        // product makes Xcode schedule the plugin twice when the root package
        // is opened directly. External apps depend on EditorCore and
        // AdjustmentUI, which bring RawProcessingCore in transitively.
        .library(name: "PresetCore", targets: ["PresetCore"]),
        .library(name: "EditorCore", targets: ["EditorCore"]),
        .library(name: "AdjustmentUI", targets: ["AdjustmentUI"]),
        // Exposed as its own product so the iPad application package (a
        // separate nested SwiftPM manifest, not a target of this package)
        // can route its user-facing text through the same `L10n` lookup as
        // every other target, instead of growing a second string system.
        .library(name: "Localization", targets: ["Localization"])
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
            exclude: ["Kernels"],
            plugins: ["CompileMetalKernels"]
        ),

        // Compiles Sources/RawProcessingCore/Kernels/*.metal into a
        // CoreImageKernels.metallib resource at build time -- `swift build`'s own
        // build system, unlike Xcode's, does not do this automatically.
        .plugin(
            name: "CompileMetalKernels",
            capability: .buildTool()
        ),

        // Preset schema, partial adjustment patches, XMP property graph, codec
        // and mapping registry. Knows RawProcessingCore's `PhotoAdjustments`
        // and nested value types, but nothing about SwiftUI, file paths,
        // security-scoped bookmarks or Core Image.
        .target(name: "PresetCore", dependencies: ["RawProcessingCore", "Localization"]),

        // Folder access, scanning, index, sidecars and caches.
        // Depends on RawProcessingCore only for the pure `PhotoAdjustments`
        // value type that the sidecar serialises. Never imports SwiftUI.
        .target(name: "PhotoLibraryCore", dependencies: ["RawProcessingCore", "PresetCore", "Localization"]),

        .target(
            name: "EditorCore",
            dependencies: ["PhotoLibraryCore", "RawProcessingCore", "PresetCore", "Localization"]
        ),
        .target(
            name: "AdjustmentUI",
            dependencies: ["EditorCore", "RawProcessingCore", "Localization"]
        ),

        // SwiftUI + AppKit layer. Never touches CIRAWFilter directly.
        .target(
            name: "LumaHarborApp",
            dependencies: ["AdjustmentUI", "EditorCore", "PhotoLibraryCore", "RawProcessingCore", "PresetCore", "Localization"]
        ),

        // Thin launcher so the SwiftUI App type stays in a testable library target.
        .executableTarget(name: "LumaHarbor", dependencies: ["LumaHarborApp"]),

        // Test-support only: a standalone process `PendingLeaseSubprocessTests`
        // launches via `Process` to prove `PendingLock` (per-document
        // pending-creation lease) contention across genuinely separate
        // processes, including surviving a `SIGKILL`. Never referenced by
        // any shipping target -- see `Sources/PendingLeaseHelper/main.swift`.
        .executableTarget(name: "PendingLeaseHelper", dependencies: ["PhotoLibraryCore"]),

        .testTarget(name: "RawProcessingCoreTests", dependencies: ["RawProcessingCore"]),
        .testTarget(
            name: "PresetCoreTests",
            dependencies: ["PresetCore", "RawProcessingCore"],
            resources: [.copy("Fixtures/XMP")]
        ),
        .testTarget(
            name: "LumaHarborAppTests",
            dependencies: ["LumaHarborApp", "EditorCore", "PhotoLibraryCore", "RawProcessingCore", "PresetCore", "Localization"]
        ),
        .testTarget(name: "PhotoLibraryCoreTests", dependencies: ["PhotoLibraryCore", "PresetCore"]),
        .testTarget(
            name: "LumaHarborIntegrationTests",
            dependencies: ["PhotoLibraryCore", "RawProcessingCore"]
        ),
        .testTarget(name: "EditorCoreTests", dependencies: ["EditorCore"]),
        .testTarget(name: "AdjustmentUITests", dependencies: ["AdjustmentUI", "EditorCore", "RawProcessingCore"])
    ]
)
