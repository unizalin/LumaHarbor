# LumaHarbor

LumaHarbor is an open-source, native, non-destructive RAW photo editor for macOS and iPadOS.

The Mac-first MVP is implemented and its automated acceptance suite passes on Apple Silicon with a full Xcode toolchain: strict-concurrency build, the complete XCTest suite, and the real-hardware `RawFixtureTests` against Sony `.ARW` files all run clean (see [`Scripts/run-mvp-acceptance.zsh`](Scripts/run-mvp-acceptance.zsh)). It browses Sony `.ARW` files directly from an external SSD, applies non-destructive basic adjustments, and exports full-resolution JPEG files. The UI follows macOS's own Language & Region setting; English and Traditional Chinese are currently translated. The manual acceptance checklist (bookmark lifecycle across APFS/exFAT, SSD reconnect, UI/performance walkthrough) in [`docs/superpowers/specs/2026-08-15-mac-first-mvp-acceptance-plan.md`](docs/superpowers/specs/2026-08-15-mac-first-mvp-acceptance-plan.md) is still in progress before the MVP can be signed off as complete. iPadOS support will follow after the Mac-first workflow is stable.

## Design

The approved Mac-first MVP specification is available in [`docs/superpowers/specs/2026-08-13-mac-first-mvp-design.md`](docs/superpowers/specs/2026-08-13-mac-first-mvp-design.md).

## Running it

```sh
swift run LumaHarbor
```

Or open [`Package.swift`](Package.swift) in Xcode and run the `LumaHarbor` scheme.

## License

LumaHarbor is available under the [MIT License](LICENSE).

## Acknowledgements

LumaHarbor is an independent Swift implementation. Its early product exploration was informed in part by [AwayPhotoRawEditor](https://github.com/awaysu/AwayPhotoRawEditor) by Awaysu. LumaHarbor is not affiliated with or endorsed by that project or its author. No AwayPhotoRawEditor source code, artwork, icons, or user interface assets are included in this repository.
