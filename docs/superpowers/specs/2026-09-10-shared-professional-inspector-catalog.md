# P2：Shared Professional Inspector Catalog 實作規格

- 狀態：核准，進入實作
- 日期：2026-09-10
- 依據：`docs/superpowers/specs/2026-09-10-professional-editing-completion-design.md` §7.1、§9、§11.3（第 18-20 條）
- 前置：P0（已完成）。不依賴 P1，可與 P1 平行，但本輪在 P1 之後才開工。
- 範圍鎖定：只做「container/catalog」工作 —— 共用 domain／section／field catalog、搜尋、收藏、smart follow、pin、section／domain reset，以及兩平台入口收斂。不重做或提前實作 curve/histogram 渲染邏輯（P3）、Lens/Color/Mask（P4/P5）、Snapshot（P6）。

## 1. 問題與現況缺口

驗證時間：2026-09-10，對照 HEAD `0353dfd`。

1. **兩份平行 catalog**：Mac `Sources/LumaHarborApp/Views/InspectorView.swift` 用私有 `InspectorGroup` enum（`basic, color, curve, detail, effects, geometry, local`）與 `MacBasicAdjustmentPanel.toneKinds/whiteBalanceKinds` 常數；iPad `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorView.swift` 用另一份 `PadInspectorHost`/`PadToolRail`（"inlined for xcodeproj fixed source list"）與 `PadAdjustSubmodeKinds`。兩者各自硬編碼欄位清單，沒有單一宣告點。
2. **欄位聲明與實際渲染脫節（真實 bug）**：`PadAdjustSubmodeKinds.color` 宣告涵蓋 `basic.temperature`、`basic.tint`、`basic.vibrance`、`basic.saturation`、24 個 `hsl.*`，但 `PadInspectorHost.adjustContent` 的 `.color` case 只掛載 `ColorAdjustmentPanel`（純 HSL）——White Balance 與 vibrance/saturation 滑桿在 iPad 上完全沒有渲染路徑。Mac 端則把 vibrance/saturation 放在 Basic、White Balance+HSL 放在 Color。兩邊欄位歸屬彼此不一致，也違反 §11.3 第 18 條（Mac 與 iPad 必須顯示相同 domain/section/field）。
3. **沒有搜尋、收藏、smart follow、pin、section/domain reset**：兩平台都沒有這些能力；`EditorSession.toolMode`（`.adjust/.crop/.whiteBalance/.linearGradient/.spotHeal`）與 `selectedLocalAdjustmentID` 已存在但未被 Inspector 使用。
4. **本地化缺口先例**：iPad 既有的 preset 收藏字串（`"Remove favorite"`、`"Add favorite"`、`"Search Presets"` 等）從未加入 `Localizable.strings`，一律 fallback 回英文 key 本身。本次新增字串不得重蹈覆轍。

## 2. 決策：欄位歸屬統一（解決缺口 2）

以 Mac 現有、已完整渲染且已有測試鎖定的分組為準：

| Catalog section | 欄位 | Mac 對應 | iPad 對應（修正後）|
| --- | --- | --- | --- |
| `basic` | exposure, contrast, highlights, shadows, whites, blacks, vibrance, saturation | `.basic` DisclosureGroup | `.light` submode |
| `whiteBalance` | basic.temperature, basic.tint | `.color` DisclosureGroup（上半） | `.color` submode（新增掛載，修正缺口 2）|
| `hsl` | 24 個 `hsl.<band>.<hue|saturation|luminance>` | `.color` DisclosureGroup（下半） | `.color` submode |
| `curve` | advancedToneCurve | `.curve` DisclosureGroup | `.light` submode |
| `detail` | sharpening.*、noiseReduction.* | `.detail` DisclosureGroup | `.detail` submode |
| `effects` | vignette.*、grain.* | `.effects` DisclosureGroup | `.detail` submode |
| `geometry` | （結構化，非純量欄位；沿用 `GeometryAdjustments`）| `.geometry` DisclosureGroup | `.geometry` domain |
| `local` | （結構化陣列；沿用 `[LocalAdjustment]`）| `.local` DisclosureGroup | `.local` domain |

`vibrance`/`saturation` 從 iPad 的 `color` submode 移到 `light`，與 Mac 一致；這是刻意的行為修正，會反映在 `PadInspectorCoordinatorTests` 既有斷言的更新上（見 §6 測試計畫），並在 handoff 中明確記錄為行為變更。

## 3. 資料模型（`Sources/AdjustmentUI/InspectorCatalog/`）

```swift
public enum InspectorSectionID: String, CaseIterable, Codable, Sendable, Identifiable, Hashable {
    case basic, whiteBalance, hsl, curve, detail, effects, geometry, local
}

public enum InspectorPlatform: String, CaseIterable, Codable, Sendable { case mac, iPad }

public struct InspectorSectionDescriptor: Identifiable, Equatable, Sendable {
    public let id: InspectorSectionID
    public let domain: PadInspectorDomain        // 既有型別，沿用不重新命名
    public let submode: PadAdjustSubmode?         // nil = 該 domain 沒有 submode 概念
    public let titleKey: String                   // 對應既有 L10n key（如 "Basic"）
    public let symbol: String
    public let fieldIDs: [String]                 // 與既有 PadAdjustSubmodeKinds / AdjustmentKind.rawValue 相容
    public let searchTokens: [String]              // 英文同義詞，供搜尋比對
    public let isFavoritable: Bool
    public let platforms: Set<InspectorPlatform>
}

public enum InspectorCatalog {
    public static let allSections: [InspectorSectionDescriptor]
    public static func section(_ id: InspectorSectionID) -> InspectorSectionDescriptor
    public static func sections(in domain: PadInspectorDomain) -> [InspectorSectionDescriptor]
    public static func sections(in submode: PadAdjustSubmode) -> [InspectorSectionDescriptor]
    public static func search(_ query: String) -> [InspectorSectionDescriptor]
    public static func resetting(_ id: InspectorSectionID, in adjustments: PhotoAdjustments) -> PhotoAdjustments
    public static func resetting(domain: PadInspectorDomain, in adjustments: PhotoAdjustments) -> PhotoAdjustments
    public static func isNeutral(_ id: InspectorSectionID, in adjustments: PhotoAdjustments) -> Bool
    public static func isNeutral(domain: PadInspectorDomain, in adjustments: PhotoAdjustments) -> Bool
}
```

`PadAdjustSubmodeKinds.light/color/detail` 與 Mac 的 `MacBasicAdjustmentPanel.toneKinds/whiteBalanceKinds` 改為從 `InspectorCatalog` 衍生（computed），不再各自維護獨立陣列常數 —— 這是「新增 field 只需在共用 catalog 宣告一次」的落地方式。`PadInspectorDomain`、`PadAdjustSubmode`、`PadInspectorPresentation` 三個既有型別維持原名與既有 raw value，不因本次重構改名（避免不必要的相容性破壞）。

`reset` 是純函式，不做 I/O、不碰 undo；呼叫端（`EditorSession.updateAdjustments`）負責 undo/autosave 整合。

## 4. 搜尋、收藏、Smart Follow、Pin（`InspectorNavigationModel`）

```swift
@MainActor
public final class InspectorNavigationModel: ObservableObject {
    @Published public var searchQuery: String
    @Published public private(set) var isPinned: Bool
    @Published public private(set) var activeSectionID: InspectorSectionID

    public var searchResults: [InspectorSectionDescriptor] { get }
    public func clearSearch()
    public func togglePin()
    public func select(_ section: InspectorSectionID)      // 明確導覽（搜尋結果點擊、favorite 點擊）
    public func follow(toolMode: EditorToolMode)             // canvas 工具切換時呼叫；pin 時不動作
    public func isFavorite(_ section: InspectorSectionID) -> Bool
    public func toggleFavorite(_ section: InspectorSectionID)
}
```

Smart Follow 對應規則（`InspectorSmartFollow.section(for:)`，純函式）：

| `EditorToolMode` | 對應 section |
| --- | --- |
| `.crop` | `.geometry` |
| `.whiteBalance` | `.whiteBalance` |
| `.linearGradient` | `.local` |
| `.spotHeal` | `.local` |
| `.adjust` | 不動作（保留使用者當前 section）|

收藏只存裝置本機 preferences（`UserDefaults`，經 `InspectorFavoritesPersisting` 協定注入，測試用記憶體假實作，不寫真實 `UserDefaults`）。Pin 為 session-local 狀態，不落盤、不建立 undo。

## 5. 兩平台入口

- **Mac** `InspectorView.swift`：在既有 header 加入搜尋欄、pin 按鈕；每個 `inspectorGroup` DisclosureGroup 標題列加入 favorite star 與該 section／對應 domain 的 reset 按鈕；`.onChange(of: model.editor.toolMode)` 呼叫 `navigation.follow`；搜尋非空時以 `ScrollViewReader` 捲到符合的 section 並展開。既有 7 個 DisclosureGroup、其標題 key 與掛載的 panel 型別不變（`InspectorAdjustmentGroupsContractTests`／`EditorWorkflowUXContractTests` 鎖定的字面文字保留)。
- **iPad** `PadEditorView.swift`：`PadInspectorHost`/`PadToolRail` 保留（因 `.xcodeproj` 固定成員清單限制，見下方「工程限制」），但兩者的欄位/domain 詞彙改為引用 `AdjustmentUI.PadAdjustSubmodeKinds`／`InspectorCatalog`，不再自行宣告。新增：`compactDomainBar`／`PadToolRail` 旁加入搜尋按鈕（開啟搜尋 sheet，重用 `InspectorNavigationModel.searchResults`）、favorite star、pin 按鈕、每個 domain header 的 reset 按鈕。`.color` submode 新增掛載 `BasicAdjustmentPanel(kinds: InspectorCatalog.section(.whiteBalance).adjustmentKinds)`（修正缺口 2）。

### 工程限制（沿用既有專案事實，不重新協商）

`Apps/LumaHarborPad.xcodeproj` 的原始碼成員清單是手動維護的固定列表（非萬用字元），目前只包含 `PadEditorView.swift` 等既有檔案，不包含 `Sources/LumaHarborPadApp/PadInspectorHost.swift`／`PadToolRail.swift`（這兩個獨立檔案已確認不在 `.pbxproj` 的 `PBXSourcesBuildPhase` 內，等同死碼，`xcodebuild` 不會編譯到）。本次不新增 `.swiftpm` app target 底下的新檔案，也不編輯 `.xcodeproj` 成員清單（避免簽署/專案設定風險）；新共用邏輯一律放進 `Sources/AdjustmentUI/*`（既有 SwiftPM library product，兩個 app target 都已透過 package dependency 引用，不需要修改 `.pbxproj`）。

## 6. 測試計畫（TDD：先紅後綠）

| 檔案 | 內容 |
| --- | --- |
| `Tests/AdjustmentUITests/InspectorCatalogTests.swift` | 8 個 section 皆存在且唯一；`fieldIDs` 跨 section 不重疊；`sections(in:)` 對應 §2 表格；`resetting(_:in:)` 只影響該 section 的欄位，其餘不變；`resetting(domain:in:)` 對應多個 section；`isNeutral` 正確；`search` 以 fieldID/token/titleKey 命中。 |
| `Tests/AdjustmentUITests/InspectorFavoritesStoreTests.swift` | 記憶體假 store 的收藏 round-trip；`InspectorFavoritesModel` 發布變更；預設空集合。 |
| `Tests/AdjustmentUITests/InspectorSmartFollowTests.swift` | §4 對照表逐一驗證；`.adjust` 不改變目前 section。 |
| `Tests/AdjustmentUITests/InspectorNavigationModelTests.swift` | pin 時 `follow` 不生效；unpin 後恢復；`select` 一律生效（即使 pin）；search 過濾。 |
| `Tests/AdjustmentUITests/PadInspectorCoordinatorTests.swift`（更新既有）| vibrance/saturation 斷言由 color 移至 light；其餘既有斷言不變；新增 disjoint 檢查涵蓋新分配。 |
| `Tests/LumaHarborAppTests/InspectorSharedCatalogContractTests.swift` | 原始碼層級驗證 Mac `InspectorView.swift` 確實呼叫 `InspectorCatalog`／`InspectorNavigationModel`（不是自行宣告第二份欄位清單）；搜尋欄、pin、favorite、reset 的字面呼叫存在。 |
| `Tests/AdjustmentUITests/PadCatalogWiringContractTests.swift` | 原始碼層級驗證 `PadEditorView.swift` 的 `.color` submode 掛載 `whiteBalance` kinds；`PadInspectorHost`/`PadToolRail` 不再宣告自己的欄位陣列常數；搜尋/favorite/pin/reset 呼叫存在。 |
| `Tests/LocalizationTests/InspectorCatalogLocalizationTests.swift`（新建測試目錄）| 8 語言 `Localizable.strings` key 集合完全一致（parity）；新增的 P2 keys 在全部 8 語言都存在且非空；en/zh-Hant 值人工核可（非 key passthrough）。 |

## 7. Accessibility／Adaptive layout

- 新增的搜尋欄、favorite star、pin 按鈕、reset 按鈕在 iPad 上維持既有 44×44 pt 最小觸控區（沿用 `PadToolRail.railButton` 既有寫法）。
- 每個新控制項提供 `.accessibilityLabel`；pin 狀態、favorite 狀態透過 `.accessibilityAddTraits(.isSelected)`／文字狀態揭露，不只靠顏色。
- 不假設裝置型號；沿用既有 `PadEditorLayoutPolicy`／`PadWorkspaceLayoutPolicy` 依 scene width 決定版面，本次不修改這兩個 policy 的既有規則。
- Dynamic Type：新文字一律用 `Text`/`Label` + 現有字型修飾，不使用固定像素裁切文字的容器。

## 8. 完成證據格式

沿用 P0/P1 handoff 的四狀態（`PASS`/`FAIL`/`SKIPPED`/`NOT RUN`）與指令記錄慣例。最低限度：

1. 本規格列出的所有新測試檔案先紅後綠的證據（測試數、失敗訊息摘要、修正後 PASS）。
2. `swift test`（全量）、`swift build -Xswiftc -strict-concurrency=complete`、iPad generic Simulator `xcodebuild`（`CODE_SIGNING_ALLOWED=NO`）、`git diff --check`、本輪 diff 的隱私掃描。
3. 8 語言 key parity 掃描結果。
4. 未執行項目（真機人工驗收等）一律標記 `NOT RUN`，不得標 `PASS`。

## 9. 明確排除

- 不新增/修改 Brush、Radial、Range、AI mask（P5）。
- 不修改 `AdvancedToneCurve`、`CurveAdjustmentPanel` 內部渲染邏輯、LUT 或 XMP（P3）。
- 不修改 Lens、Presence、Color Grading、Monochrome、Rendering Profile（P4）。
- 不修改 Snapshot、A/B、Soft Proof（P6）。
- 不修改 `.xcodeproj` 成員清單或簽署設定。
- 不修改既有 Preset 收藏/搜尋 UI（`PadPresetLibrary`／`PresetBrowserView`），僅記錄其既有本地化缺口作為前車之鑑，不在本輪修補（超出範圍）。
