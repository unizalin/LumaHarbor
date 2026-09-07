# Small-group alpha distribution

This guide covers sharing LumaHarbor with a small number of known testers without publishing it in an app store.

## Release status

LumaHarbor is pre-release alpha software. Test only with copied or fully backed-up photo libraries. Do not present an alpha build as notarized, production-ready, or fully accepted while a required manual gate remains `NOT RUN`.

## macOS: recommended path

For a build that ordinary testers can open without weakening Gatekeeper:

1. Join the Apple Developer Program.
2. Build the release configuration.
3. Sign the app with a `Developer ID Application` certificate and Hardened Runtime.
4. Submit it to Apple's notary service and staple the ticket.
5. Verify the stapled app with `codesign` and `spctl`.
6. Package it as a ZIP or DMG and publish the SHA-256 checksum with the tested commit.

This is direct distribution outside the Mac App Store. It does not require an App Store product listing.

The repository's current helper only creates a local ad-hoc build:

```sh
Scripts/build-app-bundle.sh release
codesign --verify --deep --strict build/LumaHarbor.app
ditto -c -k --keepParent build/LumaHarbor.app build/LumaHarbor-alpha.zip
shasum -a 256 build/LumaHarbor-alpha.zip
```

An ad-hoc ZIP is acceptable only for a short, explicitly trusted test. Gatekeeper may block it after download. Testers may use Finder's **Open** contextual command or macOS **Privacy & Security > Open Anyway** after confirming the sender and checksum. Do not ask testers to disable Gatekeeper globally.

## iPad: recommended path

Use TestFlight for a small external group when a paid Apple Developer account is available. TestFlight does not require a public App Store listing, although the first external beta build is subject to Apple's beta review and each build expires.

Ad Hoc distribution is an alternative for a fixed set of known devices. It requires registering each device UDID and rebuilding the provisioning profile when the device list changes. Keep the Development Team, certificates, profiles, and UDIDs out of Git.

The stable project entry point is `Apps/LumaHarborPad.xcodeproj`; see `docs/development/ipad-xcode-runbook.md`.

## What to send

- the app ZIP or TestFlight invitation;
- version, build number, and tested commit;
- SHA-256 checksum for direct downloads;
- this alpha warning and the known-issues list;
- a short feedback template that avoids full local paths and private photos.

Do not distribute private RAW fixtures, signing credentials, provisioning profiles, Xcode user data, local databases, or `.lumaharbor` sidecars from a real photo library.

## Tester checklist

1. Back up or copy the test photo folder.
2. Confirm the app opens without disabling system-wide security controls.
3. Add a folder and verify its RAW files remain unchanged.
4. Apply edits, quit, reopen, and confirm adjustments persist.
5. Export to a new empty folder and compare dimensions and metadata choices.
6. Report crashes, unexpected writes, path disclosure, or data loss immediately through the security process.

LumaHarbor may create `.lumaharbor` sidecars beside writable source photos. It also stores indexes, bookmarks, thumbnails, presets, and app-copy documents in the user's Application Support container. Removing the app does not automatically remove those files.
