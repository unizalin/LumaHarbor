# LumaHarbor Semantic Release Versioning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `MAJOR.MINOR.PATCH` the only public LumaHarbor version name while retaining a synchronized, internal Apple build number for Mac and iPad deployment.

**Architecture:** Keep the existing platform metadata (`CFBundleShortVersionString`／`MARKETING_VERSION` and `CFBundleVersion`／`CURRENT_PROJECT_VERSION`) but enforce parity with contract tests. Extract release artifact naming and collision checks into a small Bash helper consumed by the Mac packager, so the ZIP is version-only and an already published semantic version fails closed instead of being overwritten.

**Tech Stack:** Swift 6／XCTest、Bash 3.2-compatible scripts、PropertyListSerialization、Xcode project text contract、SwiftPM、xcodebuild、CoreDevice (`xcrun devicectl`).

## Global Constraints

- Public product versions use only `MAJOR.MINOR.PATCH`; the current public version remains exactly `0.1.0`.
- Mac and iPad public versions must match; Mac and iPad internal build numbers must also match.
- Internal build `3` remains deployment metadata and must not appear in the product name or Mac release archive filename.
- A second release archive for the same semantic version must fail closed; a distributable rebuild requires a `PATCH` bump.
- `Alpha` may describe project maturity but must not be appended to the product version or release archive filename.
- Bundle identifiers, signing Team, provisioning data, device identifiers, Lightroom renderer policy, RAW behavior, and Gate 2 state are out of scope.
- Signing identities and physical-device identifiers remain local-only and must never enter Git.

---

### Task 1: Version-only Mac artifact naming with fail-closed collision handling

**Files:**
- Create: `Scripts/release-versioning.sh`
- Modify: `Scripts/package-mac-release.sh:15-45,73-82`
- Test: `Tests/LumaHarborAppTests/MacReleasePackagingContractTests.swift`

**Interfaces:**
- Consumes: `APP_NAME`, `CFBundleShortVersionString`, output archive and checksum paths.
- Produces: Bash functions `release_archive_name <app-name> <semantic-version>` and `assert_release_artifacts_available <archive-path> <checksum-path>`.

- [ ] **Step 1: Write failing process and contract tests**

Append tests equivalent to:

```swift
func testReleaseArchiveNameUsesOnlySemanticVersion() throws {
    let packageScript = try text("Scripts/package-mac-release.sh")

    XCTAssertTrue(
        packageScript.contains(
            #"ARCHIVE_NAME="$(release_archive_name "${APP_NAME}" "${VERSION}")""#
        )
    )
    XCTAssertFalse(packageScript.contains(#"${APP_NAME}-${VERSION}-${BUILD_NUMBER}.zip"#))
}

func testReleaseVersioningHelperRejectsExistingArtifacts() throws {
    let helper = url("Scripts/release-versioning.sh")
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("LumaHarborReleaseVersioning-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let archive = root.appendingPathComponent("LumaHarbor-0.1.0.zip")
    let checksum = root.appendingPathComponent("LumaHarbor-0.1.0.zip.sha256")
    FileManager.default.createFile(atPath: archive.path, contents: Data())

    let result = try runBash(
        #"source "$1"; assert_release_artifacts_available "$2" "$3""#,
        arguments: [helper.path, archive.path, checksum.path]
    )
    XCTAssertEqual(result.status, 3)
    XCTAssertTrue(result.stderr.contains("already exists"))
}

func testReleaseVersioningHelperProducesVersionOnlyName() throws {
    let helper = url("Scripts/release-versioning.sh")
    let result = try runBash(
        #"source "$1"; release_archive_name LumaHarbor 0.1.0"#,
        arguments: [helper.path]
    )

    XCTAssertEqual(result.status, 0)
    XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                   "LumaHarbor-0.1.0.zip")
}
```

Add a private test helper that launches `/bin/bash` with `Process`, passes `-c`, a neutral `$0`, then the provided arguments, and captures stdout／stderr separately. Do not replace this with a source-string-only collision test.

- [ ] **Step 2: Run the focused tests and confirm RED**

Run:

```sh
swift test --filter MacReleasePackagingContractTests
```

Expected: FAIL because `Scripts/release-versioning.sh` does not exist and the package script still uses `${APP_NAME}-${VERSION}-${BUILD_NUMBER}.zip`.

- [ ] **Step 3: Implement the minimal Bash helper**

Create:

```bash
#!/bin/bash

release_archive_name() {
    local app_name="$1"
    local version="$2"
    if [[ ! "${version}" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
        echo "error: invalid semantic version: ${version}" >&2
        return 2
    fi
    printf '%s-%s.zip\n' "${app_name}" "${version}"
}

assert_release_artifacts_available() {
    local archive_path="$1"
    local checksum_path="$2"
    if [[ -e "${archive_path}" || -e "${checksum_path}" ]]; then
        echo "error: release artifact already exists; bump the product version before publishing again" >&2
        return 3
    fi
}
```

In `Scripts/package-mac-release.sh`, source the helper after `ROOT_DIR` is known, retain `BUILD_NUMBER` for technical logging, replace `ARCHIVE_NAME`, and call the collision guard before any build starts:

```bash
source "${ROOT_DIR}/Scripts/release-versioning.sh"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${INFO_PLIST}")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${INFO_PLIST}")"
ARCHIVE_NAME="$(release_archive_name "${APP_NAME}" "${VERSION}")"
ARCHIVE_PATH="${OUTPUT_DIR}/${ARCHIVE_NAME}"
CHECKSUM_PATH="${ARCHIVE_PATH}.sha256"

assert_release_artifacts_available "${ARCHIVE_PATH}" "${CHECKSUM_PATH}"
echo "==> Product version ${VERSION}; internal build ${BUILD_NUMBER}"
```

Keep `rm -f "${ARCHIVE_PATH}"` inside `package_zip`: it is needed to replace the pre-notarization ZIP within the same process after stapling. The new preflight guard is what prevents overwriting an artifact from an earlier invocation.

- [ ] **Step 4: Run focused tests and shell syntax checks**

Run:

```sh
bash -n Scripts/release-versioning.sh
bash -n Scripts/package-mac-release.sh
swift test --filter MacReleasePackagingContractTests
```

Expected: all commands exit 0; focused XCTest suite PASS.

- [ ] **Step 5: Commit Task 1**

```sh
git add Scripts/release-versioning.sh Scripts/package-mac-release.sh Tests/LumaHarborAppTests/MacReleasePackagingContractTests.swift
git commit -m "fix: use semantic versions for release artifacts"
```

**Stop condition:** Stop if the helper cannot run under `/bin/bash` 3.2, if a pre-existing archive is overwritten, or if notarization repackaging is blocked within the same invocation.

**Do not touch:** `Resources/Info.plist`, the iPad Xcode project, app bundle identifiers, signing, notarization credentials, or product rendering code.

---

### Task 2: Cross-platform public-version and internal-build contract

**Files:**
- Create: `Tests/LumaHarborAppTests/ReleaseVersionContractTests.swift`
- Modify: `README.md:67-80,121-156`

**Interfaces:**
- Consumes: Mac `Resources/Info.plist`, iPad `Apps/LumaHarborPad.xcodeproj/project.pbxproj`, and public README artifact examples.
- Produces: XCTest contract that independently verifies public SemVer parity, positive internal build parity, and version-only public naming.

- [ ] **Step 1: Add the failing release-version contract tests**

Create a test case that loads the Mac plist with `PropertyListSerialization`, extracts repeated Xcode settings with `NSRegularExpression`, and asserts:

```swift
func testMacAndIPadUseTheSameSemanticVersion() throws {
    let mac = try macBundleMetadata()
    let project = try text("Apps/LumaHarborPad.xcodeproj/project.pbxproj")
    let ipadVersions = values(for: "MARKETING_VERSION", in: project)

    XCTAssertTrue(mac.version.range(of: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"#,
                                            options: .regularExpression) != nil)
    XCTAssertEqual(Set(ipadVersions), [mac.version])
    XCTAssertEqual(ipadVersions.count, 2)
}

func testMacAndIPadUseTheSamePositiveInternalBuild() throws {
    let mac = try macBundleMetadata()
    let project = try text("Apps/LumaHarborPad.xcodeproj/project.pbxproj")
    let ipadBuilds = values(for: "CURRENT_PROJECT_VERSION", in: project)

    XCTAssertGreaterThan(Int(mac.build) ?? 0, 0)
    XCTAssertEqual(Set(ipadBuilds), [mac.build])
    XCTAssertEqual(ipadBuilds.count, 2)
}

func testPublicDocumentationUsesVersionOnlyArtifactNames() throws {
    let readme = try text("README.md")
    XCTAssertTrue(readme.contains("LumaHarbor-<version>.zip"))
    XCTAssertFalse(readme.contains("LumaHarbor-<version>-<build>.zip"))
    XCTAssertFalse(readme.contains("0.1.0 (3)"))
}
```

The `values(for:in:)` helper must capture `KEY = value;` and return every target configuration occurrence. The plist helper must throw if either required key is missing.

- [ ] **Step 2: Run the contract tests and confirm RED**

Run:

```sh
swift test --filter ReleaseVersionContractTests
```

Expected: FAIL because README still documents `LumaHarbor-<version>-<build>.zip`.

- [ ] **Step 3: Make the smallest README correction**

Replace the checksum example and artifact list with:

```text
shasum -a 256 LumaHarbor-<version>.zip

- `LumaHarbor-<version>.zip`
- 同名的 `.zip.sha256`
```

Replace “只分享最高 build number” with a rule that only one archive exists per semantic version and any republished product requires a patch bump. Keep the maturity warning as prose; do not append `Alpha` to `0.1.0`.

- [ ] **Step 4: Run Task 2 tests**

Run:

```sh
swift test --filter ReleaseVersionContractTests
swift test --filter MacReleasePackagingContractTests
```

Expected: both suites PASS; Mac and iPad remain public version `0.1.0`, internal build `3`.

- [ ] **Step 5: Commit Task 2**

```sh
git add Tests/LumaHarborAppTests/ReleaseVersionContractTests.swift README.md
git commit -m "test: enforce cross-platform release versions"
```

**Stop condition:** Stop if Mac and iPad metadata differ, if either public version is not `x.y.z`, or if a test requires committing a signing Team or personal bundle identifier.

**Do not touch:** The current values `0.1.0` and `3`, Xcode signing fields, iPad display name, bundle identifiers, product source, or sidecar schema.

---

### Task 3: Durable version terminology across agent and release documentation

**Files:**
- Modify: `AGENTS.md:48-54`
- Modify: `README.md:47-80,121-156`
- Modify: `docs/coordination/SHARED_GIT_WORKFLOW.md:88-101`
- Modify: `docs/coordination/DECISIONS.md`
- Modify: `docs/coordination/CURRENT.md:5-13`
- Modify: `docs/testing/beta/SMALL_GROUP_ALPHA.md:45-58`

**Interfaces:**
- Consumes: approved semantic-version spec and Task 2 contract terminology.
- Produces: one durable cross-agent decision and consistent user／technical wording.

- [ ] **Step 1: Extend the failing documentation contract**

Add assertions to `ReleaseVersionContractTests` that the three durable entry points contain the exact concepts:

```swift
func testAgentAndWorkflowDocsSeparateProductVersionFromInternalBuild() throws {
    let agents = try text("AGENTS.md")
    let workflow = try text("docs/coordination/SHARED_GIT_WORKFLOW.md")
    let decisions = try text("docs/coordination/DECISIONS.md")

    XCTAssertTrue(agents.contains("MAJOR.MINOR.PATCH"))
    XCTAssertTrue(agents.contains("internal build"))
    XCTAssertTrue(workflow.contains("產品版本"))
    XCTAssertTrue(workflow.contains("內部 build"))
    XCTAssertTrue(decisions.contains("D-011 — Public releases use semantic versions"))
}
```

- [ ] **Step 2: Run the test and confirm RED**

Run:

```sh
swift test --filter ReleaseVersionContractTests.testAgentAndWorkflowDocsSeparateProductVersionFromInternalBuild
```

Expected: FAIL because D-011 and the exact shared terminology do not yet exist.

- [ ] **Step 3: Update durable documentation**

Make these exact policy changes:

- `AGENTS.md`: public releases use `MAJOR.MINOR.PATCH`; internal build remains separate and never becomes the product name or archive name.
- `SHARED_GIT_WORKFLOW.md`: release preparation synchronizes both fields across Mac／iPad, but public artifacts use only product version.
- `DECISIONS.md`: append `D-011 — Public releases use semantic versions`; record that current public version is `0.1.0`, internal build is `3`, and repeated distribution requires a patch bump.
- `CURRENT.md`: write “產品版本 `0.1.0`，內部 build `3`” and remove `0.1.0 (3)` phrasing from the current section.
- `SMALL_GROUP_ALPHA.md`: request “product version, internal build, and tested commit” as separate evidence fields. Keep “alpha” only as project maturity language.

- [ ] **Step 4: Run documentation contracts and format checks**

Run:

```sh
swift test --filter ReleaseVersionContractTests
git diff --check
rg -n '0\.1\.0 \(3\)|LumaHarbor-<version>-<build>|\$\{APP_NAME\}-\$\{VERSION\}-\$\{BUILD_NUMBER\}' \
  AGENTS.md README.md Scripts docs/coordination docs/testing/beta Tests
```

Expected: tests and `git diff --check` PASS; `rg` returns no matches.

- [ ] **Step 5: Commit Task 3**

```sh
git add AGENTS.md README.md docs/coordination/SHARED_GIT_WORKFLOW.md docs/coordination/DECISIONS.md docs/coordination/CURRENT.md docs/testing/beta/SMALL_GROUP_ALPHA.md Tests/LumaHarborAppTests/ReleaseVersionContractTests.swift
git commit -m "docs: standardize semantic release naming"
```

**Stop condition:** Stop if documentation implies internal build can be omitted from technical evidence, if “Alpha” is removed from safety warnings rather than only version names, or if CURRENT claims any unrun product gate passed.

**Do not touch:** Historical reports and specs, existing Git tags or branches, Lightroom evidence, device identifiers, private fixture references, or signing configuration.

---

### Task 4: Full release-tooling verification and post-merge device synchronization

**Files:**
- Verify only before merge: all Task 1-3 files
- Update after successful product-version push: `docs/coordination/CURRENT.md`

**Interfaces:**
- Consumes: version-only packager, metadata contracts, user-authorized merge／push, local-only signing environment.
- Produces: reproducible ZIP/checksum evidence and truthful Mac／iPad deployment states tied to the pushed `main` SHA.

- [ ] **Step 1: Run focused and complete automated tests**

```sh
swift test --filter 'MacReleasePackagingContractTests|ReleaseVersionContractTests'
swift test
swift build -Xswiftc -strict-concurrency=complete
```

Expected: all commands exit 0; report exact executed, skipped, and failed counts.

- [ ] **Step 2: Build and package in an empty isolated release directory**

```sh
RELEASE_DIR="$(mktemp -d /private/tmp/LumaHarborSemVerRelease.XXXXXX)"
LUMAHARBOR_RELEASE_DIR="${RELEASE_DIR}" Scripts/package-mac-release.sh release
test -f "${RELEASE_DIR}/LumaHarbor-0.1.0.zip"
test -f "${RELEASE_DIR}/LumaHarbor-0.1.0.zip.sha256"
test ! -e "${RELEASE_DIR}/LumaHarbor-0.1.0-3.zip"
```

Run the package command a second time against the same directory. Expected: exit 3 with “already exists”; the first ZIP and checksum remain unchanged.

- [ ] **Step 3: Verify platform builds and privacy**

```sh
Scripts/verify-release-privacy.sh build/LumaHarbor.app
xcodebuild \
  -project Apps/LumaHarborPad.xcodeproj \
  -scheme LumaHarborPad \
  -configuration Release \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/LumaHarborSemVerSimulator \
  CODE_SIGNING_ALLOWED=NO \
  build
git diff --check
```

Expected: privacy scan, generic iPad build, and diff check PASS.

- [ ] **Step 4: Perform final privacy scan**

Scan tracked additions and release artifacts for private absolute paths, signing Team, provisioning UUIDs, device identifiers, private RAW／XMP／TIFF names, and credentials. Expected: no matches. Do not print any local identifier into a committed report.

- [ ] **Step 5: Obtain explicit merge／push authorization**

Before merge or push, report branch, HEAD, commits, changed files, test counts, release artifact names, and remaining `NOT RUN` gates. Continue only after the user explicitly authorizes merge and push to `main`.

- [ ] **Step 6: After push, synchronize the Mac installation**

From the exact pushed `main` SHA, rebuild Release, move an older `/Applications/LumaHarbor.app` to Trash, install the newly built `LumaHarbor.app`, verify product version `0.1.0`, internal build `3`, codesign, and launch smoke. Record only non-private status in `CURRENT.md`.

- [ ] **Step 7: If a paired iPad is reachable, synchronize it**

Use local-only environment variables rather than committing identifiers:

```sh
test -n "${LUMAHARBOR_DEVELOPMENT_TEAM:?local signing Team is required}"
test -n "${LUMAHARBOR_DEVICE_ID:?local paired device identifier is required}"
xcodebuild \
  -project Apps/LumaHarborPad.xcodeproj \
  -scheme LumaHarborPad \
  -configuration Release \
  -destination "id=${LUMAHARBOR_DEVICE_ID}" \
  -derivedDataPath /private/tmp/LumaHarborSemVerDevice \
  DEVELOPMENT_TEAM="${LUMAHARBOR_DEVELOPMENT_TEAM}" \
  build
xcrun devicectl device install app \
  --device "${LUMAHARBOR_DEVICE_ID}" \
  /private/tmp/LumaHarborSemVerDevice/Build/Products/Release-iphoneos/LumaHarborPad.app
xcrun devicectl device process launch \
  --device "${LUMAHARBOR_DEVICE_ID}" \
  --terminate-existing \
  org.lumaharbor.LumaHarborPad
```

Expected: installed metadata reports product version `0.1.0`, internal build `3`, and launch succeeds. If the device or signing environment is unavailable, record `NOT RUN` or `BLOCKED`; do not substitute the simulator result.

- [ ] **Step 8: Commit the post-push coordination evidence only if it changed**

```sh
git add docs/coordination/CURRENT.md
git commit -m "docs: record semantic release deployment"
```

Push this coordination-only commit only with explicit user authorization. Per project policy, it does not trigger another rebuild or device deployment.

**Stop condition:** Stop on any test/build/privacy failure, package overwrite, Mac/iPad version mismatch, signing leak, or unavailable required authorization. Keep device deployment `NOT RUN` when hardware is unavailable.

**Do not touch:** Lightroom renderer enablement, production registry, RAW/XMP fixtures, sidecars, user photo libraries, signing credentials, device identifiers, app bundle identifiers, historical release archives, or `main` before authorization.
