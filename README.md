# LumaHarbor

LumaHarbor is an open-source, native, non-destructive RAW photo editor for macOS and iPadOS. It is an independently implemented Swift reimplementation developed as a second-generation project informed by AwayPhotoRawEditor, built with SwiftUI, Core Image, CryptoKit, and SQLite.

> **Project status:** pre-release alpha. The automated build and test suites are healthy, but several hands-on Mac, external-drive, translation, and iPad checks remain open. Use copies or backed-up photo libraries while testing.

## Highlights

- Browse RAW folders and external drives without importing or modifying source files.
- Apply non-destructive basic, color, detail, effects, geometry, local-mask, gradient, spot-heal, and clone adjustments.
- Save portable edit sidecars, create virtual copies, and organize reusable presets.
- Export individual or selected photos with resizing, bit depth, metadata, naming, collision, DPI, and text-watermark options.
- Browse multiple sources on iPad, retain indexes and cached thumbnails while a source is offline, and relink it later.
- Use adaptive iPad workspace widths, touch-first photo selection, rating/flag/keyword filters, and a safe-area batch bar.
- Use English, Traditional Chinese, Simplified Chinese, Japanese, Korean, German, French, or Spanish UI text.
- Keep editing local: shipping targets contain no analytics, account system, cloud backend, or application-level network client.

RAW compatibility follows the platform's `CIRAWFilter` support. Sony `.ARW` files are the project's mandatory real-fixture format.

## Requirements

- macOS 14 or later
- Xcode with the matching Command Line Tools
- Xcode's Metal Toolchain component (`xcodebuild -downloadComponent MetalToolchain`)
- iOS or iPadOS 17 or later for the iPad target

## Run on macOS

From the repository root:

```sh
swift run LumaHarbor
```

For a local `.app` bundle:

```sh
Scripts/build-app-bundle.sh release
open build/LumaHarbor.app
```

The script creates an ad-hoc signed development build. It is suitable for local testing, not a trusted public release. See the [small-group alpha distribution guide](docs/testing/beta/SMALL_GROUP_ALPHA.md) before sharing a build.

For a repeatable Mac release archive:

```sh
Scripts/package-mac-release.sh release
```

This writes a versioned ZIP and SHA-256 checksum under `dist/`. Without signing environment variables it creates an ad-hoc archive for local or explicitly trusted alpha testing. For a trusted public release, install a Developer ID Application certificate and a `notarytool` Keychain profile, then run:

```sh
LUMAHARBOR_SIGNING_IDENTITY='Developer ID Application: ...' \
LUMAHARBOR_NOTARY_PROFILE='LumaHarbor-notary' \
Scripts/package-mac-release.sh release
```

The signing identity and notarization credentials stay outside the repository.

### Install a prebuilt Mac archive

1. Download the ZIP and its `.sha256` checksum from the same release location.
2. Verify the archive before opening it:

   ```sh
   shasum -a 256 LumaHarbor-<version>-<build>.zip
   ```

3. Extract the ZIP and open `LumaHarbor.app`.
4. For an ad-hoc alpha build, use Finder's **Open** contextual command on the first launch. If macOS still blocks it, use **System Settings > Privacy & Security > Open Anyway** after confirming the source and checksum.

Do not disable Gatekeeper globally. A Developer ID-signed and notarized release should open without this alpha-only override step.

## Run on iPad

Open `Apps/LumaHarborPad.xcodeproj`, select the `LumaHarborPad` scheme and choose a simulator or device. Real-device installation requires selecting your own Development Team in Xcode; personal signing settings must not be committed.

The complete setup is in the [iPad Xcode runbook](docs/development/ipad-xcode-runbook.md).

For a short Traditional Chinese walkthrough of both platforms, see the [quick start guide](docs/testing/beta/QUICK_START_ZH-HANT.md).

## Basic workflow / 使用方式

### macOS

1. Prepare a copied or fully backed-up photo folder. Do not use the only copy of a photo library for alpha testing.
2. Launch LumaHarbor and choose **Add Photo Folder…**.
3. Wait for indexing to finish, then open a RAW photo from the browser.
4. Adjust exposure, color, detail, effects, geometry, local adjustments, or other available controls.
5. Use **Save Adjustments** (`⌘S`) to save the non-destructive edit. The original RAW remains unchanged; writable folders may receive a `.lumaharbor` sidecar beside the source photo.
6. Use **Export JPEG…** for one photo or **Export Selected Photos…** for a batch. Export to a new output folder instead of mixing exports into the source folder.
7. Use the library filter menu for rating, flag, edited-state, keyword, camera, lens, format, and capture-date queries; use Select mode when choosing several visible photos.

Presets can be created from an open photo and imported or exported as `.xmp` or `.lhpreset` files. The preset library also supports backup and restore archives.

### iPadOS

For your own iPad, open `Apps/LumaHarborPad.xcodeproj`, select your Development Team in **Signing & Capabilities**, choose the physical iPad, and press **Run**. The iPad workflow supports multiple photo sources, reconnecting an offline source, browsing, editing, and non-destructive save state; the full device setup and test sequence are in the [iPad Xcode runbook](docs/development/ipad-xcode-runbook.md) and [tester guide](docs/testing/beta/TESTER_GUIDE.md).

## 分享給其他人

Mac 版可以分享壓縮檔；iPad 版不能直接把 Mac ZIP 拿去安裝。完成驗測後，在專案根目錄執行：

    Scripts/package-mac-release.sh release

產物會在 dist/：

- LumaHarbor-<version>-<build>.zip
- 同名的 .zip.sha256

把 ZIP、checksum 與測試 commit 一起提供。對方先用 shasum -a 256 驗證，再解壓縮並開啟 LumaHarbor.app；ad-hoc alpha 首次可能要在 Finder 右鍵選「打開」，或到「系統設定 > 隱私權與安全性」按「仍要打開」。不要要求對方關閉 Gatekeeper。正式對外下載則必須先完成 Developer ID 簽章與 notarization。

## Verify

```sh
swift build
swift test
swift run LumaHarborDiagnosticsCLI
swift run LumaHarborDiagnosticsCLI --json
```

Fixture and device-dependent acceptance remains separate from the ordinary test suite. Current evidence and open manual gates are tracked in [`docs/coordination/CURRENT.md`](docs/coordination/CURRENT.md).

## Current release limitations

- The project is pre-release alpha software. Use copied or backed-up photo libraries.
- The default Mac bundle and ZIP use an ad-hoc signature. A public download should use Developer ID signing and notarization.
- The current prebuilt Mac archive is Apple Silicon (`arm64`) and requires macOS 14 or later. Source builds follow the host architecture.
- iPad builds require local Development Team signing for a personal device. External testers need TestFlight, Ad Hoc distribution, or their own Xcode signing.
- The additional Japanese, Korean, Simplified Chinese, German, French, and Spanish translations are machine-assisted and still need native-language review before a production release.

## Data and privacy

LumaHarbor reads the folders users explicitly select. Depending on the workflow, it stores `.lumaharbor` sidecars beside source photos and keeps indexes, bookmarks, thumbnails, presets, and app-copy documents in the user's Application Support container. These local records may contain filenames and metadata and are not separately encrypted by LumaHarbor.

Source RAW files are intended to remain immutable. Security-sensitive defects should be reported through the process in [`SECURITY.md`](SECURITY.md), not in a public issue.

## Design and development

The original Mac MVP design is in [`docs/superpowers/specs/2026-08-13-mac-first-mvp-design.md`](docs/superpowers/specs/2026-08-13-mac-first-mvp-design.md). The iPad multi-source design and implementation plan are in [`docs/superpowers/specs/2026-08-26-ipad-multi-source-photo-library-design.md`](docs/superpowers/specs/2026-08-26-ipad-multi-source-photo-library-design.md) and [`docs/superpowers/plans/2026-08-26-ipad-multi-source-photo-library.md`](docs/superpowers/plans/2026-08-26-ipad-multi-source-photo-library.md).

Contributions should preserve RAW immutability, dependency-free shipping targets, path-free user-facing diagnostics, and the distinction between automated `PASS`, fixture `SKIPPED`, and hardware `NOT RUN` evidence.

## License

LumaHarbor is available under the [MIT License](LICENSE).

## Source Attribution / 二次開發

LumaHarbor is a macOS/iPadOS reimplementation and second-development project informed by [AwayPhotoRawEditor](https://github.com/awaysu/AwayPhotoRawEditor).

- **Original project:** [AwayPhotoRawEditor](https://github.com/awaysu/AwayPhotoRawEditor)
- **Original author:** [Awaysu](https://github.com/awaysu)
- **Original project license:** BSD 3-Clause, as identified by the original repository

Please retain this attribution when redistributing LumaHarbor. LumaHarbor is not affiliated with or endorsed by AwayPhotoRawEditor or its author. This repository does not redistribute AwayPhotoRawEditor source code, artwork, icons, or user-interface assets; LumaHarbor's own source remains available under the [MIT License](LICENSE).
