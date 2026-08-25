// swift-tools-version: 5.9
import PackageDescription
import AppleProductTypes

let package = Package(
    name: "LumaHarborPad",
    platforms: [.iOS("17.0")],
    products: [
        .iOSApplication(
            name: "LumaHarborPad",
            targets: ["LumaHarborPadApp"],
            bundleIdentifier: "com.unizalin.LumaHarborPad",
            displayVersion: "0.1.0",
            bundleVersion: "1",
            appIcon: .placeholder(icon: .images),
            accentColor: .presetColor(.blue),
            supportedDeviceFamilies: [.pad],
            supportedInterfaceOrientations: [
                .portrait,
                .portraitUpsideDown,
                .landscapeRight,
                .landscapeLeft
            ]
        )
    ],
    dependencies: [
        .package(name: "LumaHarbor", path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "LumaHarborPadApp",
            dependencies: [
                .product(name: "EditorCore", package: "LumaHarbor"),
                .product(name: "AdjustmentUI", package: "LumaHarbor"),
                .product(name: "PhotoLibraryCore", package: "LumaHarbor"),
                .product(name: "RawProcessingCore", package: "LumaHarbor")
            ],
            path: "Sources/LumaHarborPadApp"
        )
    ]
)
