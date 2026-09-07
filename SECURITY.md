# Security Policy

## Supported versions

LumaHarbor is pre-release software. Security fixes are applied to the current `main` branch; older commits and locally shared alpha builds are not maintained as separate release lines.

## Reporting a vulnerability

Please use [GitHub private vulnerability reporting](https://github.com/unizalin/LumaHarbor/security/advisories/new) for vulnerabilities involving:

- modification or deletion of source RAW files;
- path traversal or writes outside a user-selected destination;
- malicious RAW, XMP, preset, sidecar, or library metadata;
- disclosure of local paths, photo metadata, bookmarks, or other private data;
- signature, distribution, or dependency-integrity problems.

Do not include private photo files, credentials, signing identities, full local paths, or exploit details in a public issue. Include the affected commit, macOS or iPadOS version, a minimal reproduction using synthetic data when possible, and the expected security boundary.

The maintainers will acknowledge a report, reproduce it where possible, coordinate a fix, and publish an advisory when disclosure is appropriate. Because this is a small volunteer project, no fixed response-time SLA is promised.

## Current distribution posture

Development bundles produced by `Scripts/build-app-bundle.sh` are ad-hoc signed. They are not Developer ID signed, hardened, or notarized and should be treated as local or explicitly trusted alpha builds. The current app is not sandboxed.

Shipping targets are intentionally dependency-free and contain no application-level network client, analytics SDK, account system, or cloud backend. LumaHarbor still processes complex, untrusted media and metadata through Apple frameworks, so reports about parser inputs and filesystem boundaries are welcome.
