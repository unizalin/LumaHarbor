# iPad Xcode runbook

Updated: 2026-09-01

For a short Traditional Chinese walkthrough of installing to your own iPad, see [`docs/testing/beta/QUICK_START_ZH-HANT.md`](../testing/beta/QUICK_START_ZH-HANT.md).

## Use this project for real-device iPad testing

Open:

```text
Apps/LumaHarborPad.xcodeproj
```

Do not use `Apps/LumaHarborPad.swiftpm/Package.swift` for ongoing real-device work. That nested App Playground manifest is Xcode-generated and can be rewritten by the Xcode app settings UI, which removes the app target's package-product dependencies and causes errors such as:

```text
Unable to resolve module dependency: 'EditorCore'
Unable to resolve module dependency: 'AdjustmentUI'
Unable to resolve module dependency: 'PhotoLibraryCore'
Unable to resolve module dependency: 'Localization'
```

`Apps/LumaHarborPad.xcodeproj` is the stable iPad app entry point. It references the repository root as a local Swift package and links the iPad app target to the required package products.

## First-time setup

1. Open `Apps/LumaHarborPad.xcodeproj` in Xcode.
2. Select the `LumaHarborPad` scheme.
3. Select a real iPad as the run destination.
4. In Signing & Capabilities, choose your Development Team.
5. If Xcode shows stale build errors, run Product → Clean Build Folder.
6. Run the app.

Signing state is local machine state. Do not commit a personal Development Team unless a release/signing policy explicitly asks for it.

## Command-line verification

Use this command to confirm the project still resolves the local package dependency graph:

```bash
xcodebuild -project Apps/LumaHarborPad.xcodeproj \
  -scheme LumaHarborPad \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Expected result:

```text
** BUILD SUCCEEDED **
```

The target dependency graph should include the root package products `EditorCore`, `AdjustmentUI`, `PhotoLibraryCore`, and `Localization`.
