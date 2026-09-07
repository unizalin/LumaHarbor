# LumaHarbor

LumaHarbor is an open-source, native, non-destructive RAW photo editor for macOS and iPadOS. It is an independent Swift implementation built with SwiftUI, Core Image, CryptoKit, and SQLite.

> **Project status:** pre-release alpha. The automated build and test suites are healthy, but several hands-on Mac, external-drive, translation, and iPad checks remain open. Use copies or backed-up photo libraries while testing.

## Highlights

- Browse RAW folders and external drives without importing or modifying source files.
- Apply non-destructive basic, color, detail, effects, geometry, local-mask, gradient, spot-heal, and clone adjustments.
- Save portable edit sidecars, create virtual copies, and organize reusable presets.
- Export individual or selected photos with resizing, bit depth, metadata, naming, collision, DPI, and text-watermark options.
- Browse multiple sources on iPad, retain indexes and cached thumbnails while a source is offline, and relink it later.
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

## Run on iPad

Open `Apps/LumaHarborPad.xcodeproj`, select the `LumaHarborPad` scheme and choose a simulator or device. Real-device installation requires selecting your own Development Team in Xcode; personal signing settings must not be committed.

The complete setup is in the [iPad Xcode runbook](docs/development/ipad-xcode-runbook.md).

## Verify

```sh
swift build
swift test
swift run LumaHarborDiagnosticsCLI
swift run LumaHarborDiagnosticsCLI --json
```

Fixture and device-dependent acceptance remains separate from the ordinary test suite. Current evidence and open manual gates are tracked in [`docs/coordination/CURRENT.md`](docs/coordination/CURRENT.md).

## Data and privacy

LumaHarbor reads the folders users explicitly select. Depending on the workflow, it stores `.lumaharbor` sidecars beside source photos and keeps indexes, bookmarks, thumbnails, presets, and app-copy documents in the user's Application Support container. These local records may contain filenames and metadata and are not separately encrypted by LumaHarbor.

Source RAW files are intended to remain immutable. Security-sensitive defects should be reported through the process in [`SECURITY.md`](SECURITY.md), not in a public issue.

## Design and development

The original Mac MVP design is in [`docs/superpowers/specs/2026-08-13-mac-first-mvp-design.md`](docs/superpowers/specs/2026-08-13-mac-first-mvp-design.md). The iPad multi-source design and implementation plan are in [`docs/superpowers/specs/2026-08-26-ipad-multi-source-photo-library-design.md`](docs/superpowers/specs/2026-08-26-ipad-multi-source-photo-library-design.md) and [`docs/superpowers/plans/2026-08-26-ipad-multi-source-photo-library.md`](docs/superpowers/plans/2026-08-26-ipad-multi-source-photo-library.md).

Contributions should preserve RAW immutability, dependency-free shipping targets, path-free user-facing diagnostics, and the distinction between automated `PASS`, fixture `SKIPPED`, and hardware `NOT RUN` evidence.

## License

LumaHarbor is available under the [MIT License](LICENSE).

## Acknowledgements

Early product exploration was informed in part by [AwayPhotoRawEditor](https://github.com/awaysu/AwayPhotoRawEditor) by Awaysu. LumaHarbor is not affiliated with or endorsed by that project or its author. No AwayPhotoRawEditor source code, artwork, icons, or user interface assets are included in this repository.
