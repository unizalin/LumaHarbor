# iPad 直向非侵入式 Inspector Implementation Plan

> **執行狀態：已完成**（產品提交 `20f739d4ba6040c6d2e8d1f1c128820e835ec80a`；實機視覺驗收記為 `NOT RUN`）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 讓 iPad 直向編輯器可以完全收起 Inspector，以不改變畫布版面的側邊圓形按鈕或上方入口重新開啟，並修正五項 domain 在窄版面只顯示一項的問題。

**Architecture:** 將 bottom drawer 是否顯示與側邊 launcher 是否顯示收斂成 `AdjustmentUI` 的純 policy；`PadEditorView` 只同步這個 policy 與 `PadInspectorCoordinator.isInspectorVisible`，把 launcher 疊在 canvas 上而不參與 layout。窄版 domain bar 使用明確的幾何寬度平均分配五項，並同步修正獨立 host 與 Xcode inline host 的相同呈現。

**Tech Stack:** Swift 6、SwiftUI、SwiftPM、XCTest、iPadOS 17+。

## Global Constraints

- RAW 原檔、sidecar、`EditorSession`、調整值與 undo／redo 不因面板開合或版面變更而改寫。
- Compact／Standard 以實際可用寬度決定；不得依裝置名稱或 orientation 判斷。
- 側邊 launcher 命中區至少 44×44 pt，且使用 safe-area 內的 overlay，不占 canvas layout 空間。
- 直向 sheet 必須同時提供 Adjust、Presets、Geometry、Local、Info 五個 domain。
- 測試必須先寫出失敗案例，再加入最小實作；未授權的 `project.pbxproj` signing 變更必須保留且不可提交。

---

### Task 1: 建立 bottom drawer／launcher 純狀態 policy

**Files:**
- Modify: `Sources/AdjustmentUI/PadEditorLayoutPolicy.swift`
- Test: `Tests/AdjustmentUITests/PadEditorLayoutPolicyTests.swift`

**Interfaces:**
- Consumes: `PadWorkspaceMode`、`PadInspectorPresentation` 與 coordinator 的 `isInspectorVisible` 值。
- Produces: `PadBottomDrawerPolicy.presentation(mode:inspectorPresentation:isInspectorVisible:) -> PadDrawerPresentation` 與 `PadBottomDrawerPolicy.shouldShowLauncher(mode:inspectorPresentation:isInspectorVisible:) -> Bool`。

- [x] **Step 1: Write the failing tests**

在 `PadEditorLayoutPolicyTests` 的 `PadBottomDrawerPolicy` 區段加入：

```swift
func testBottomDrawerIsDismissedWhenInspectorIsHidden() {
    XCTAssertEqual(
        PadBottomDrawerPolicy.presentation(
            mode: .work,
            inspectorPresentation: .bottomDrawer,
            isInspectorVisible: false
        ),
        .dismissed
    )
}

func testLauncherAppearsOnlyForHiddenCompactInspector() {
    XCTAssertTrue(
        PadBottomDrawerPolicy.shouldShowLauncher(
            mode: .work,
            inspectorPresentation: .bottomDrawer,
            isInspectorVisible: false
        )
    )
    XCTAssertFalse(
        PadBottomDrawerPolicy.shouldShowLauncher(
            mode: .work,
            inspectorPresentation: .bottomDrawer,
            isInspectorVisible: true
        )
    )
    XCTAssertFalse(
        PadBottomDrawerPolicy.shouldShowLauncher(
            mode: .focus,
            inspectorPresentation: .bottomDrawer,
            isInspectorVisible: false
        )
    )
    XCTAssertFalse(
        PadBottomDrawerPolicy.shouldShowLauncher(
            mode: .work,
            inspectorPresentation: .trailingDock,
            isInspectorVisible: false
        )
    )
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `swift test --filter 'PadEditorLayoutPolicyTests/testBottomDrawerIsDismissedWhenInspectorIsHidden|PadEditorLayoutPolicyTests/testLauncherAppearsOnlyForHiddenCompactInspector'`

Expected: FAIL because the policy has no visibility-aware overload or launcher predicate.

- [x] **Step 3: Write minimal implementation**

在 `PadBottomDrawerPolicy` 中把現有方法改成帶預設值的 visibility-aware signature，並加入 launcher predicate：

```swift
public static func presentation(
    mode: PadWorkspaceMode,
    inspectorPresentation: PadInspectorPresentation,
    isInspectorVisible: Bool = true
) -> PadDrawerPresentation {
    mode == .work && inspectorPresentation == .bottomDrawer && isInspectorVisible
        ? .presented
        : .dismissed
}

public static func shouldShowLauncher(
    mode: PadWorkspaceMode,
    inspectorPresentation: PadInspectorPresentation,
    isInspectorVisible: Bool
) -> Bool {
    mode == .work && inspectorPresentation == .bottomDrawer && !isInspectorVisible
}
```

保留原有呼叫點的預設參數，讓既有 policy tests 與其他 caller 不需同時改寫。

- [x] **Step 4: Run test to verify it passes**

Run: `swift test --filter 'PadEditorLayoutPolicyTests/testBottomDrawerIsDismissedWhenInspectorIsHidden|PadEditorLayoutPolicyTests/testLauncherAppearsOnlyForHiddenCompactInspector|PadEditorLayoutPolicyTests'`

Expected: 新增案例與既有 `PadEditorLayoutPolicyTests` 全部 PASS。

- [x] **Step 5: Commit**

```bash
git add Sources/AdjustmentUI/PadEditorLayoutPolicy.swift Tests/AdjustmentUITests/PadEditorLayoutPolicyTests.swift
git commit -m "feat: model dismissible portrait inspector"
```

### Task 2: 固定窄版五項 domain bar 的等寬配置

**Files:**
- Modify: `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorView.swift:1029-1053`
- Modify: `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadInspectorHost.swift:57-91`
- Test: `Tests/AdjustmentUITests/PadPortraitInspectorContractTests.swift`

**Interfaces:**
- Consumes: 既有五項 `PadInspectorDomain` 順序與 `PadInspectorCoordinator.selectDomain(_:)`。
- Produces: inline 與 standalone host 都使用同一個可容納五項的 compact domain bar，保留 44 pt 命中高度與 selected accessibility trait。

- [x] **Step 1: Write the failing contract tests**

建立 `PadPortraitInspectorContractTests.swift`，以現有 source-contract 路徑載入兩份 host，加入：

```swift
import XCTest

final class PadPortraitInspectorContractTests: XCTestCase {
    private static let appSourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp")

    private static func load(_ name: String) throws -> String {
        try String(contentsOf: appSourceURL.appendingPathComponent(name), encoding: .utf8)
    }

    func testBothHostsUseExplicitFiveItemEqualWidthBar() throws {
        for name in ["PadEditorView.swift", "PadInspectorHost.swift"] {
            let source = try Self.load(name)
            XCTAssertTrue(source.contains("GeometryReader"), "\(name) must size the compact domain bar from its available width")
            XCTAssertTrue(source.contains("domainBarItems.count"), "\(name) must derive each tab width from the five-item count")
            XCTAssertTrue(source.contains("minHeight: 44"), "\(name) must keep the compact domain bar hit target")
        }
    }

    func testInlineHostHasAllFiveDomainEntries() throws {
        let source = try Self.load("PadEditorView.swift")
        for key in [".adjust", ".preset", ".geometry", ".local", ".info"] {
            XCTAssertTrue(source.contains("DomainBarItem(id: \(key)"))
        }
    }
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `swift test --filter PadPortraitInspectorContractTests`

Expected: FAIL because neither compact bar uses a `GeometryReader`-based equal-width layout.

- [x] **Step 3: Write minimal implementation**

在兩份 host 的 `compactDomainBar` 將 `HStack` 內容改為可測量寬度的等寬配置，使用下列結構（兩份保持相同）：

```swift
private var compactDomainBar: some View {
    GeometryReader { proxy in
        let spacing: CGFloat = 8
        let availableWidth = max(0, proxy.size.width - spacing * CGFloat(Self.domainBarItems.count - 1))
        let itemWidth = max(44, availableWidth / CGFloat(Self.domainBarItems.count))

        HStack(spacing: spacing) {
            ForEach(Self.domainBarItems) { item in
                let isSelected = inspector.activeDomain == item.id
                Button {
                    inspector.selectDomain(item.id)
                } label: {
                    Image(systemName: item.symbol)
                        .imageScale(.medium)
                        .frame(width: itemWidth, minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .background(
                    isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .accessibilityLabel(Text(L10n.t(item.labelKey)))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .frame(width: proxy.size.width)
    }
    .frame(height: 52)
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
}
```

`PadEditorView.swift` 的 inline host 與 `PadInspectorHost.swift` 的 standalone host 都必須保留五項相同順序；不要把 domain bar 重新拆成另一個調整資料來源。

- [x] **Step 4: Run test to verify it passes**

Run: `swift test --filter 'PadPortraitInspectorContractTests|PadToolRailContractTests|PadPresetContractTests'`

Expected: 全部 PASS。

- [x] **Step 5: Commit**

```bash
git add Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorView.swift Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadInspectorHost.swift Tests/AdjustmentUITests/PadPortraitInspectorContractTests.swift
git commit -m "fix: show all portrait inspector domains"
```

### Task 3: 接上可關閉 sheet、上方入口與側邊圓形 launcher

**Files:**
- Modify: `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorView.swift:118-145, 260-390, 454-497, 704-748`
- Test: `Tests/AdjustmentUITests/PadPortraitInspectorContractTests.swift`

**Interfaces:**
- Consumes: `PadBottomDrawerPolicy.presentation(...)`、`shouldShowLauncher(...)`、`PadInspectorCoordinator.isInspectorVisible`。
- Produces: `inspectorToggle`、`inspectorLauncher`、`shouldShowInspectorLauncher`、`setInspectorVisible(_:)`；上方與側邊入口開啟同一個 `isDrawerPresented` sheet。

- [x] **Step 1: Write the failing contract tests**

在 `PadPortraitInspectorContractTests` 加入：

```swift
func testEditorExposesBothInspectorEntrypointsAndDismissibleSheet() throws {
    let source = try Self.load("PadEditorView.swift")
    XCTAssertTrue(source.contains("inspectorLauncher"))
    XCTAssertTrue(source.contains("inspectorToggle"))
    XCTAssertTrue(source.contains("L10n.t(\"Show Inspector\")"))
    XCTAssertTrue(source.contains("interactiveDismissDisabled(false)"))
    XCTAssertTrue(source.contains("PadBottomDrawerPolicy.shouldShowLauncher"))
    XCTAssertTrue(source.contains("overlay(alignment: .trailing)"))
}

func testInspectorLauncherUsesA44PointCircularHitTarget() throws {
    let source = try Self.load("PadEditorView.swift")
    XCTAssertTrue(source.contains("frame(width: 44, height: 44)"))
    XCTAssertTrue(source.contains("Circle()"))
    XCTAssertTrue(source.contains("Show, hide, or resize workspace panels"))
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `swift test --filter PadPortraitInspectorContractTests`

Expected: FAIL because the editor currently has no side launcher, no visibility-aware sheet binding, and disables interactive dismissal.

- [x] **Step 3: Write minimal implementation**

1. 在 toolbar 內加入 `inspectorToggle`，按鈕只更新 coordinator visibility：

```swift
ToolbarItem(placement: .primaryAction) {
    inspectorToggle
}
```

2. 移除 `.interactiveDismissDisabled(true)`，改為 `.interactiveDismissDisabled(false)`，使使用者能向下關閉 sheet。

3. 在 `GeometryReader` 的 modifier chain 加入 `onChange(of: inspector.isInspectorVisible)`，並讓 `updateDrawerPresentation()` 使用 visibility-aware policy：

```swift
private var isBottomDrawerPresentation: Bool {
    PadEditorLayoutPolicy.presentation(forWidth: availableSize.width, height: availableSize.height) == .bottomDrawer
}

private var shouldShowInspectorLauncher: Bool {
    PadBottomDrawerPolicy.shouldShowLauncher(
        mode: workspaceState.workspaceMode,
        inspectorPresentation: PadEditorLayoutPolicy.presentation(
            forWidth: availableSize.width,
            height: availableSize.height
        ),
        isInspectorVisible: inspector.isInspectorVisible
    )
}

private func setInspectorVisible(_ visible: Bool) {
    inspector.isInspectorVisible = visible
    updateDrawerPresentation()
}

private func updateDrawerPresentation() {
    let inspectorPresentation = PadEditorLayoutPolicy.presentation(
        forWidth: availableSize.width,
        height: availableSize.height
    )
    let target = PadBottomDrawerPolicy.presentation(
        mode: workspaceState.workspaceMode,
        inspectorPresentation: inspectorPresentation,
        isInspectorVisible: inspector.isInspectorVisible
    ) == .presented
    if isDrawerPresented != target {
        isDrawerPresented = target
    }
}
```

4. 用 `onChange(of: isDrawerPresented)` 只在窄版 user dismiss 時將 coordinator visibility 設為 false；若是 resize／focus 造成的 policy dismiss，不清除 coordinator domain state：

```swift
.onChange(of: isDrawerPresented) { _, presented in
    if isBottomDrawerPresentation && !presented && inspector.isInspectorVisible {
        inspector.isInspectorVisible = false
    }
}
```

5. 在 `canvas` 的最外層加入 overlay。launcher 必須使用 safe-area 內的 44 pt 圓形命中區，不呼叫 `.frame` 改變 canvas 尺寸：

```swift
.overlay(alignment: .trailing) {
    if shouldShowInspectorLauncher {
        inspectorLauncher
            .padding(.trailing, 12)
    }
}
```

6. 加入上方與側邊共用的入口元件：

```swift
private var inspectorToggle: some View {
    Button {
        setInspectorVisible(!inspector.isInspectorVisible)
    } label: {
        Image(systemName: "slider.horizontal.3")
    }
    .disabled(!isBottomDrawerPresentation)
    .accessibilityLabel(Text(L10n.t(inspector.isInspectorVisible ? "Hide Inspector" : "Show Inspector")))
}

private var inspectorLauncher: some View {
    Button {
        setInspectorVisible(true)
    } label: {
        Image(systemName: "slider.horizontal.3")
            .frame(width: 44, height: 44)
            .background(.regularMaterial, in: Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text(L10n.t("Show Inspector")))
    .accessibilityHint(Text(L10n.t("Show, hide, or resize workspace panels")))
}
```

上方按鈕在 trailing dock 仍 disabled，避免宣稱可以隱藏實際未接 visibility 的 dock；窄版則完整支援開關。若 sheet 被手勢關閉，`onChange` 會讓 launcher 出現；再次點擊任一入口只會重新使用既有 sheet。

- [x] **Step 4: Run test to verify it passes**

Run: `swift test --filter 'PadPortraitInspectorContractTests|PadEditorLayoutPolicyTests|PadToolRailContractTests'`

Expected: 全部 PASS，且沒有 editor state 相關 failure。

- [x] **Step 5: Commit**

```bash
git add Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorView.swift Tests/AdjustmentUITests/PadPortraitInspectorContractTests.swift
git commit -m "feat: add nonintrusive portrait inspector launcher"
```

### Task 4: 全量驗證與人工視覺檢查記錄

**Files:**
- Verify: `Apps/LumaHarborPad.xcodeproj/project.pbxproj`（只確認既有 signing-only dirty 狀態，不修改）
- Verify: `docs/superpowers/specs/2026-09-15-ipad-portrait-nonintrusive-inspector-design.md`

**Interfaces:**
- Consumes: Tasks 1–3 的 policy、domain bar 與 editor composition。
- Produces: 可重現的 focused tests、完整 Swift tests、generic iOS build 與明確的人工驗收狀態。

- [x] **Step 1: Run focused tests**

Run: `swift test --filter 'PadPortraitInspectorContractTests|PadEditorLayoutPolicyTests|PadToolRailContractTests|PadInspectorCoordinatorTests|PadPresetContractTests'`

Expected: PASS，且測試報告中的 skip／failure 都被明確記錄。

- [x] **Step 2: Run complete Swift tests**

Run: `swift test`

Expected: 完整 suite 完成；既有環境差異需分開標示，不得把未執行或既有 failure 說成 PASS。

- [x] **Step 3: Run generic iOS build**

Run: `xcodebuild -project Apps/LumaHarborPad.xcodeproj -scheme LumaHarborPad -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`

Expected: `** BUILD SUCCEEDED **`；不得因本次驗證修改 `project.pbxproj` 的 signing 設定。

- [x] **Step 4: Run diff and source checks**

Run: `git diff --check`; `rg -n 'DEVELOPMENT_TEAM|/Users/|/Volumes/|bookmark' docs/superpowers/plans/2026-09-15-ipad-portrait-nonintrusive-inspector.md docs/superpowers/specs/2026-09-15-ipad-portrait-nonintrusive-inspector-design.md`

Expected: `git diff --check` 無輸出；新增文件不含私人路徑、Team ID 或 bookmark 資料。

- [x] **Step 5: Record manual visual QA honestly**

在可操作 iPad 上驗證：直向收起不遮照片；側邊與上方入口都能開啟；五項 domain 同時可見；medium／large 拖曳及向下關閉不改變調整；旋轉與 Stage Manager resize 保留 domain、zoom、undo。若本環境無法操作實機，將各項記為 `NOT RUN`，不以 source contract 取代。

- [x] **Step 6: Commit verification notes only if needed**

若需要更新驗證紀錄，僅加入與本次變更相關的 repository-relative evidence；不要 stage `Apps/LumaHarborPad.xcodeproj/project.pbxproj`。

## Self-review checklist

- [x] 五個 domain、launcher、sheet dismissal 與畫布不占位都有對應 task。
- [x] 每個 production change 都先有明確 RED test，再做最小 GREEN implementation。
- [x] `PadBottomDrawerPolicy` 的新參數有預設值，既有 caller 與 tests 保持型別一致。
- [x] inline 與 standalone host 的 domain bar 都有同步修改，不會只修到其中一個 build path。
- [x] 上方入口在 trailing dock 不宣稱能隱藏未接線的 dock；Compact／Standard 才負責 sheet 開關。
- [x] 不會提交既有 Xcode signing-only dirty file。
