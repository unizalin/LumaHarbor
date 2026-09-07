# LumaHarbor App Icon、使用與小範圍分發 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 建立港灣光圈品牌圖示並接入 macOS／iPadOS App，同時提供準確的 Mac 使用、iPad 安裝與小範圍分發文件。

**Architecture:** 以一張 1024×1024 不透明主圖作為唯一視覺來源，透過可重跑的 shell script 產生 Mac `.icns`，iPad asset catalog 直接使用同一主圖。以 XCTest source-contract 鎖住兩個 target 的接線，再用真實 Mac bundle 與 Xcode asset compiler 驗證產物；文件沿用既有 alpha 安全與 iPad runbook，不建立第二套互相矛盾的流程。

**Tech Stack:** Swift/XCTest、ImageIO、SwiftPM、Xcode asset catalogs、`sips`、`iconutil`、Bash、macOS AppKit bundle、iPadOS 17 Xcode project、Markdown。

## Global Constraints

- 主圖必須為 1024×1024、不透明 PNG，不能含文字、字母、浮水印或透明圓角。
- 視覺採「港灣地平線＋相機光圈」：深墨色、青綠水面、暖金色光線，專業攝影工具質感。
- Mac 最低版本維持 macOS 14.0；iPad 最低版本維持 iPadOS 17.0。
- 不新增第三方 runtime dependency。
- 不提交 Development Team、UDID、provisioning profile、憑證或任何個人簽署設定。
- Mac 產物維持 ad-hoc、未 notarize；文件不得宣稱一般公開分發已就緒。
- iPad App 已存在且有實機 PASS 紀錄；本計畫只新增圖示、文件及最新 build 驗證。
- Mac ZIP 不能安裝到 iPad；iPad 對外分發只說明 TestFlight、Ad Hoc 或由測試者自行 Xcode 簽署。
- 不更動照片處理、匯出、sidecar 或資料模型行為。

---

### Task 1: App Icon Asset Contracts

**Files:**
- Create: `Tests/LumaHarborAppTests/AppIconAssetContractTests.swift`
- Test: `Tests/LumaHarborAppTests/AppIconAssetContractTests.swift`

**Interfaces:**
- Consumes: repository-relative `Resources/AppIcon-1024.png`、`Resources/LumaHarbor.icns`、`Resources/Info.plist`、`Scripts/build-app-bundle.sh`、iPad asset catalog 與 Xcode project。
- Produces: `AppIconAssetContractTests`，後續每個接線 task 都以同一個 test class 作為 gate。

- [ ] **Step 1: 建立會因目前完全沒有圖示資產而失敗的 contract tests**

```swift
import CoreGraphics
import Foundation
import ImageIO
import XCTest

final class AppIconAssetContractTests: XCTestCase {
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func url(_ path: String) -> URL {
        Self.repositoryRoot.appendingPathComponent(path)
    }

    private func text(_ path: String) throws -> String {
        try String(contentsOf: url(path), encoding: .utf8)
    }

    func testMasterIconIsOpaque1024SquarePNG() throws {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url("Resources/AppIcon-1024.png") as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 1024)
        XCTAssertEqual(image.height, 1024)
        let alphaBearingModes: Set<CGImageAlphaInfo> = [.premultipliedFirst, .premultipliedLast, .first, .last]
        XCTAssertFalse(alphaBearingModes.contains(image.alphaInfo))
    }

    func testMacBundleDeclaresAndCopiesICNS() throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: url("Resources/LumaHarbor.icns").path))
        XCTAssertTrue(try text("Resources/Info.plist").contains("CFBundleIconFile"))
        XCTAssertTrue(try text("Resources/Info.plist").contains("LumaHarbor.icns"))
        XCTAssertTrue(try text("Scripts/build-app-bundle.sh").contains("Resources/LumaHarbor.icns"))
    }

    func testIPadAssetCatalogAndProjectAreWired() throws {
        let catalog = try text("Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/Assets.xcassets/AppIcon.appiconset/Contents.json")
        XCTAssertTrue(catalog.contains("AppIcon-1024.png"))
        XCTAssertTrue(catalog.contains("1024x1024"))

        let project = try text("Apps/LumaHarborPad.xcodeproj/project.pbxproj")
        XCTAssertTrue(project.contains("Assets.xcassets in Resources"))
        XCTAssertTrue(project.contains("ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;"))
    }
}
```

- [ ] **Step 2: 執行測試確認 RED**

Run:

```bash
swift test --filter AppIconAssetContractTests
```

Expected: FAIL，第一個 failure 是 `Resources/AppIcon-1024.png` 不存在，其他 assertions 也指出 `.icns`、plist、build script 與 iPad asset catalog 尚未接線。

- [ ] **Step 3: 提交 RED tests**

```bash
git add Tests/LumaHarborAppTests/AppIconAssetContractTests.swift
git commit -m "test: define app icon asset contracts"
```

---

### Task 2: Generate the Harbor Aperture Master and Mac Icon Set

**Files:**
- Create: `Resources/AppIcon-1024.png`
- Create: `Resources/LumaHarbor.iconset/icon_16x16.png`
- Create: `Resources/LumaHarbor.iconset/icon_16x16@2x.png`
- Create: `Resources/LumaHarbor.iconset/icon_32x32.png`
- Create: `Resources/LumaHarbor.iconset/icon_32x32@2x.png`
- Create: `Resources/LumaHarbor.iconset/icon_128x128.png`
- Create: `Resources/LumaHarbor.iconset/icon_128x128@2x.png`
- Create: `Resources/LumaHarbor.iconset/icon_256x256.png`
- Create: `Resources/LumaHarbor.iconset/icon_256x256@2x.png`
- Create: `Resources/LumaHarbor.iconset/icon_512x512.png`
- Create: `Resources/LumaHarbor.iconset/icon_512x512@2x.png`
- Create: `Resources/LumaHarbor.icns`
- Create: `Scripts/generate-app-icons.sh`
- Test: `Tests/LumaHarborAppTests/AppIconAssetContractTests.swift`

**Interfaces:**
- Consumes: the approved visual design and built-in `image_gen` output.
- Produces: canonical `Resources/AppIcon-1024.png`, reproducible `Resources/LumaHarbor.iconset`, and `Resources/LumaHarbor.icns` for both platform wiring tasks.

- [ ] **Step 1: 以 built-in image generation 產生主圖**

Use this exact prompt:

```text
Use case: logo-brand
Asset type: macOS and iPadOS professional RAW photo editor app icon
Primary request: Create a polished LumaHarbor app icon combining a calm harbor horizon with a camera aperture that forms the harbor entrance.
Subject: One bold aperture/harbor symbol, readable at 32 px, with a subtle reflected light path on water.
Style/medium: premium dimensional app icon, restrained and professional, clean geometry, tactile depth, no photorealistic scene.
Composition/framing: centered symbol with generous safe margin; full 1024x1024 square; no baked rounded corners.
Lighting/mood: quiet dawn light, precise and confident.
Color palette: deep ink background, teal-green water, warm gold light; balanced multi-hue palette, no purple gradient.
Constraints: opaque background; no text, no letters, no numbers, no watermark, no camera body, no tiny details; preserve clarity from 1024 px down to 32 px.
Avoid: stock-photo appearance, neon cyberpunk colors, blue-purple dominance, beige/brown dominance, transparent corners.
```

Save the selected opaque output as `Resources/AppIcon-1024.png` and inspect it at full size before continuing.

- [ ] **Step 2: 建立可重跑的 icon generator**

```bash
#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MASTER="${ROOT_DIR}/Resources/AppIcon-1024.png"
ICONSET="${ROOT_DIR}/Resources/LumaHarbor.iconset"
ICNS="${ROOT_DIR}/Resources/LumaHarbor.icns"

test -f "${MASTER}"
mkdir -p "${ICONSET}"

sips -z 16 16 "${MASTER}" --out "${ICONSET}/icon_16x16.png"
sips -z 32 32 "${MASTER}" --out "${ICONSET}/icon_16x16@2x.png"
sips -z 32 32 "${MASTER}" --out "${ICONSET}/icon_32x32.png"
sips -z 64 64 "${MASTER}" --out "${ICONSET}/icon_32x32@2x.png"
sips -z 128 128 "${MASTER}" --out "${ICONSET}/icon_128x128.png"
sips -z 256 256 "${MASTER}" --out "${ICONSET}/icon_128x128@2x.png"
sips -z 256 256 "${MASTER}" --out "${ICONSET}/icon_256x256.png"
sips -z 512 512 "${MASTER}" --out "${ICONSET}/icon_256x256@2x.png"
sips -z 512 512 "${MASTER}" --out "${ICONSET}/icon_512x512.png"
cp "${MASTER}" "${ICONSET}/icon_512x512@2x.png"
iconutil -c icns "${ICONSET}" -o "${ICNS}"
```

Make the script executable and run it:

```bash
chmod +x Scripts/generate-app-icons.sh
Scripts/generate-app-icons.sh
```

Expected: `Resources/LumaHarbor.icns` exists and `iconutil -c iconset Resources/LumaHarbor.icns -o /private/tmp/LumaHarbor-verify.iconset` exits 0.

- [ ] **Step 3: 視覺與像素驗證**

Run:

```bash
sips -g pixelWidth -g pixelHeight -g hasAlpha Resources/AppIcon-1024.png
file Resources/LumaHarbor.icns
```

Expected: 1024×1024；`hasAlpha: no`；ICNS recognized as macOS icon resource。用 `view_image` 檢查港灣／光圈主體置中、無文字、32 px 輪廓仍清楚。

- [ ] **Step 4: 提交主圖與產生器**

```bash
git add Resources/AppIcon-1024.png Resources/LumaHarbor.iconset Resources/LumaHarbor.icns Scripts/generate-app-icons.sh
git commit -m "feat: add LumaHarbor harbor aperture icon"
```

---

### Task 3: Wire the macOS App Icon

**Files:**
- Modify: `Resources/Info.plist`
- Modify: `Scripts/build-app-bundle.sh`
- Test: `Tests/LumaHarborAppTests/AppIconAssetContractTests.swift`

**Interfaces:**
- Consumes: `Resources/LumaHarbor.icns` from Task 2.
- Produces: a Mac `.app` whose Info.plist declares `LumaHarbor.icns` and whose `Contents/Resources` contains that file.

- [ ] **Step 1: 在 Info.plist 宣告圖示**

Add immediately after `CFBundleExecutable`:

```xml
<key>CFBundleIconFile</key>
<string>LumaHarbor.icns</string>
```

- [ ] **Step 2: 在 bundle script 複製圖示**

Add after copying `Info.plist`:

```bash
cp "${ROOT_DIR}/Resources/LumaHarbor.icns" "${APP_DIR}/Contents/Resources/LumaHarbor.icns"
```

- [ ] **Step 3: 執行 focused contract test**

```bash
swift test --filter AppIconAssetContractTests/testMacBundleDeclaresAndCopiesICNS
```

Expected: PASS。

- [ ] **Step 4: 建置並檢查真 Mac bundle**

```bash
Scripts/build-app-bundle.sh release
plutil -p build/LumaHarbor.app/Contents/Info.plist
test -f build/LumaHarbor.app/Contents/Resources/LumaHarbor.icns
codesign --verify --deep --strict build/LumaHarbor.app
```

Expected: build PASS；plist 顯示 `CFBundleIconFile => LumaHarbor.icns`；file test 與 codesign exit 0。

- [ ] **Step 5: 提交 Mac 接線**

```bash
git add Resources/Info.plist Scripts/build-app-bundle.sh
git commit -m "feat: bundle app icon on macOS"
```

---

### Task 4: Wire the iPadOS App Icon

**Files:**
- Create: `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/Assets.xcassets/Contents.json`
- Create: `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/Assets.xcassets/AppIcon.appiconset/Contents.json`
- Create: `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`
- Modify: `Apps/LumaHarborPad.xcodeproj/project.pbxproj`
- Test: `Tests/LumaHarborAppTests/AppIconAssetContractTests.swift`

**Interfaces:**
- Consumes: `Resources/AppIcon-1024.png` from Task 2.
- Produces: iPad `Assets.xcassets` resource and Xcode `AppIcon` build setting without any signing identity.

- [ ] **Step 1: 建立 asset catalog metadata**

Root `Contents.json`:

```json
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

AppIcon `Contents.json`:

```json
{
  "images" : [
    {
      "filename" : "AppIcon-1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

Copy the canonical master without modification:

```bash
cp Resources/AppIcon-1024.png Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
```

- [ ] **Step 2: 將 asset catalog 接進 Xcode project**

Add one `PBXFileReference` for `Assets.xcassets`, one `PBXBuildFile` named `Assets.xcassets in Resources`, place the file reference in group `123000000000000000000002`, and place the build file in resources phase `122000000000000000000003`.

Use these currently unused stable object IDs and exact entries:

```text
12000000000000000000000E /* Assets.xcassets in Resources */ = {isa = PBXBuildFile; fileRef = 12100000000000000000000E /* Assets.xcassets */; };
12100000000000000000000E /* Assets.xcassets */ = {isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; };
```

Add this child to `123000000000000000000002`:

```text
12100000000000000000000E /* Assets.xcassets */,
```

Add this resource to `122000000000000000000003`:

```text
12000000000000000000000E /* Assets.xcassets in Resources */,
```

Add this setting to both target Debug and Release build settings:

```text
ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
```

Do not modify either existing empty `DEVELOPMENT_TEAM = "";` line.

- [ ] **Step 3: 執行 iPad contract test**

```bash
swift test --filter AppIconAssetContractTests/testIPadAssetCatalogAndProjectAreWired
```

Expected: PASS。

- [ ] **Step 4: 執行 Xcode asset/build gates**

```bash
xcodebuild -project Apps/LumaHarborPad.xcodeproj -scheme LumaHarborPad -destination 'generic/platform=iOS Simulator' -derivedDataPath /private/tmp/LumaHarbor-AppIcon-Simulator CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Apps/LumaHarborPad.xcodeproj -scheme LumaHarborPad -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/LumaHarbor-AppIcon-Device CODE_SIGNING_ALLOWED=NO build
```

Expected: both commands end with `** BUILD SUCCEEDED **` and asset compiler reports no missing AppIcon slot or alpha-channel error。

- [ ] **Step 5: 提交 iPad 接線**

```bash
git add Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/Assets.xcassets Apps/LumaHarborPad.xcodeproj/project.pbxproj
git commit -m "feat: add app icon to iPad target"
```

---

### Task 5: Mac and iPad User Guide

**Files:**
- Create: `docs/testing/beta/QUICK_START_ZH-HANT.md`
- Modify: `README.md`
- Modify: `docs/development/ipad-xcode-runbook.md`
- Modify: `docs/testing/beta/SMALL_GROUP_ALPHA.md`
- Modify: `docs/testing/beta/ALPHA_853B837_TEST_REPORT.md`
- Test: `Tests/LumaHarborAppTests/AppIconAssetContractTests.swift`

**Interfaces:**
- Consumes: current Mac ZIP limitations, stable iPad Xcode project, and prior real-device PASS evidence.
- Produces: one user-facing Traditional Chinese quick start plus links from all existing distribution entry points.

- [ ] **Step 1: 建立繁中快速入門**

The document must contain these literal headings so source review can verify coverage:

```markdown
## Mac：第一次開啟
## Mac：加入照片並開始編輯
## Mac：匯出照片
## iPad：從 Xcode 安裝到自己的 iPad
## iPad：提供給其他測試者
## 資料安全與移除
```

Mac instructions must include checksum verification, Gatekeeper right-click/Open Anyway, folder selection, RAW-safe editing, `⌘Z`/`⇧⌘Z`, persistence, export-to-empty-folder, `.lumaharbor`, and Application Support behavior.

iPad instructions must state that the app already works on iPad, use `Apps/LumaHarborPad.xcodeproj`, select the `LumaHarborPad` scheme/device/Development Team, then Run. External distribution must distinguish TestFlight, Ad Hoc, and recipient-owned Xcode signing, and must explicitly say the Mac ZIP cannot be installed on iPad.

- [ ] **Step 2: 更新既有入口文件**

Add a `快速開始` link to `README.md`; add the same link and existing real-device PASS summary to `docs/development/ipad-xcode-runbook.md`; link the quick start from both alpha distribution documents. Preserve the existing ad-hoc/notarization warnings.

- [ ] **Step 3: 執行文字與隱私檢查**

```bash
rg -n 'Mac：第一次開啟|iPad：從 Xcode 安裝到自己的 iPad|Mac ZIP 不能安裝到 iPad|TestFlight|Ad Hoc|\.lumaharbor' docs/testing/beta/QUICK_START_ZH-HANT.md
rg -n '/Users/[^<]|/Volumes/[^<]|DEVELOPMENT_TEAM = [A-Z0-9]|UDID|BEGIN PRIVATE KEY' docs/testing/beta/QUICK_START_ZH-HANT.md README.md docs/development/ipad-xcode-runbook.md docs/testing/beta/SMALL_GROUP_ALPHA.md docs/testing/beta/ALPHA_853B837_TEST_REPORT.md
```

Expected: first command finds every required topic；second command has no real private value（generic labels such as `UDID` in safety prose are allowed after manual inspection）。

- [ ] **Step 4: 提交文件**

```bash
git add README.md docs/development/ipad-xcode-runbook.md docs/testing/beta/QUICK_START_ZH-HANT.md docs/testing/beta/SMALL_GROUP_ALPHA.md docs/testing/beta/ALPHA_853B837_TEST_REPORT.md
git commit -m "docs: explain Mac and iPad alpha usage"
```

---

### Task 6: Full Verification and Updated Alpha Artifact

**Files:**
- Modify: `docs/coordination/CURRENT.md`
- Create: `build/LumaHarbor-0.1.0-alpha-${ICON_COMMIT}.zip` where `ICON_COMMIT="$(git rev-parse --short HEAD)"` (ignored release artifact, not committed)

**Interfaces:**
- Consumes: all code/assets/docs from Tasks 1-5.
- Produces: verified icon-bearing Mac ZIP, checksum, iPad build evidence, and coordination record.

- [ ] **Step 1: 執行所有 icon contracts**

```bash
swift test --filter AppIconAssetContractTests
```

Expected: all tests PASS。

- [ ] **Step 2: 執行完整 regression suite**

```bash
swift test
```

Expected: 0 failures；fixture-dependent skips 必須照實記錄。

- [ ] **Step 3: 重建 Mac App 並視覺驗證圖示**

```bash
Scripts/build-app-bundle.sh release
codesign --verify --deep --strict build/LumaHarbor.app
```

Open the app and inspect Finder/Dock using CUA or a screenshot. Expected: icon is nonblank, centered, recognizable, and no UI regressions are visible at launch.

- [ ] **Step 4: 產生新的 ZIP，不覆蓋舊 artifact**

```bash
ICON_COMMIT="$(git rev-parse --short HEAD)"
ditto -c -k --keepParent build/LumaHarbor.app "build/LumaHarbor-0.1.0-alpha-${ICON_COMMIT}.zip"
unzip -t "build/LumaHarbor-0.1.0-alpha-${ICON_COMMIT}.zip"
shasum -a 256 "build/LumaHarbor-0.1.0-alpha-${ICON_COMMIT}.zip"
```

Expected: ZIP test PASS and one SHA-256 recorded。Do not rename or overwrite `LumaHarbor-0.1.0-alpha-853b837.zip`。

- [ ] **Step 5: Final iPad builds**

```bash
xcodebuild -project Apps/LumaHarborPad.xcodeproj -scheme LumaHarborPad -destination 'generic/platform=iOS Simulator' -derivedDataPath /private/tmp/LumaHarbor-AppIcon-Final-Simulator CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Apps/LumaHarborPad.xcodeproj -scheme LumaHarborPad -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/LumaHarbor-AppIcon-Final-Device CODE_SIGNING_ALLOWED=NO build
```

Expected: both builds PASS；do not interpret unsigned generic build as a distributable IPA。

- [ ] **Step 6: 最終安全與差異檢查**

```bash
git diff --check
git status --short --branch
```

Inspect changed content for real `/Users/...`、`/Volumes/...`、non-empty Team ID、UDID、provisioning profile、API key、private key and secret values. Expected: no real private values and no unintended signing changes。

- [ ] **Step 7: 更新 coordination record 並提交**

Add a new top section to `docs/coordination/CURRENT.md` containing exact commit range, asset paths, contract/full test counts, Mac/iPad build outcomes, ZIP filename/checksum, privacy result, and the truthful remaining signing/distribution limitations.

```bash
git add docs/coordination/CURRENT.md
git commit -m "docs: record app icon distribution verification"
```

- [ ] **Step 8: Landing**

Verify both worktrees are clean, fast-forward the finished branch into `main`, push only after all checks pass, and compare `origin/main` SHA to local HEAD. Do not delete any branch or worktree.
