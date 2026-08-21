# LumaHarbor Preset 與 Lightroom XMP 相容層設計

日期：2026-08-21

狀態：已確認，待實作

基準版本：`c70ecc3`

## 1. 目的

LumaHarbor 的下一階段要提供可長期使用的原生 Preset，並讓使用者把既有 Lightroom／Adobe Camera Raw 工作成果搬入 LumaHarbor。這不是短期的「讀幾個 XML 欄位」功能，而是一條可版本化、可驗證、未知資料不遺失的相容層。

本設計包含兩個依序交付、可各自驗收的階段：

1. LumaHarbor 原生 Preset，以及 Camera Raw／Lightroom 開發預設 `.xmp` 的匯入、套用與匯出。
2. RAW 旁相鄰 Adobe `.xmp` sidecar 的偵測、搬家摘要、確認後批次匯入，以及明確的單檔／資料夾匯入。

## 2. 已確認的產品決策

- 原生 Preset、XMP 匯入與 XMP 匯出全部納入本設計。
- 不支援的 XMP 欄位必須保存；日後 LumaHarbor 支援該功能時，再透過版本化升級轉成可編輯欄位。
- 套用 Preset 提供「合併」及「完整取代」；預設為合併。
- 原生 Preset 同時支援「我的 Preset」與「此照片庫的 Preset」，並可互相複製。
- 從照片建立 Preset 時顯示欄位勾選清單；預設勾選目前已修改的項目，也可納入仍為預設值的項目。
- 第一階段先交付開發預設；第二階段再交付照片 XMP sidecar 搬家。兩者共用解析、映射與未知欄位保存機制。
- `.lumaharbor/edits/*.json` 始終是 LumaHarbor 編輯狀態的唯一正式來源。Adobe XMP 是搬家及交換格式，不做持續雙向同步。
- 掃描照片庫時可以偵測相鄰 XMP，但必須先顯示摘要並取得確認，不能自動改寫 LumaHarbor sidecar。
- 相容性採分級保證：資料語意無損；可靠欄位正確映射；近似欄位明確標示；不支援欄位只保存、不假裝已套用。
- 編輯器檢查器提供 Preset 區，包含搜尋、群組、收藏與暫時預覽；點擊套用只形成一筆 Undo。

## 3. 非目標

- 不承諾與 Adobe 處理引擎逐像素一致；兩邊演算法不同，只能對已支援欄位定義合理的數值與視覺容差。
- 不實作 Lightroom catalog（`.lrcat`）解析。
- 不實作 Lightroom virtual copy、歷史記錄、遮色片或 AI mask 的渲染。
- 不修改 RAW 原檔，也不在本階段修改 DNG 內嵌 XMP。DNG 內嵌資料只列後續相容範圍。
- 不把一般「批次套用 Preset 到任意照片集合」併入本功能；第二階段的批次僅指已確認的 XMP 搬家工作。
- 不新增第三方網路服務或在匯入時上傳 XMP／照片。

## 4. 架構邊界

### 4.1 Target 分工

新增 `PresetCore` SwiftPM target，依賴 `RawProcessingCore`：

- 定義原生 Preset schema、部分調整 patch、相容性診斷、XMP property graph、codec 與 mapping registry。
- 不知道 SwiftUI、照片庫路徑、security-scoped bookmark 或 Core Image。

`RawProcessingCore`：

- 繼續持有可渲染的 `PhotoAdjustments`。
- 提供套用需要的照片上下文，例如 as-shot temperature／tint baseline。
- 不解析 XML，也不處理 Preset 檔案。

`PhotoLibraryCore`：

- 實作使用者層級與照片庫層級 Preset repository。
- 負責原子寫入、唯讀檢查、同名／同 UUID 衝突及相鄰 XMP discovery。
- 第二階段負責把已確認的 XMP 搬家結果寫入既有 `PhotoSidecar`，不能讓 XMP 取代 repository 的資料主權。

`LumaHarborApp`：

- 負責 Preset browser、搜尋、群組、收藏、匯入摘要、建立表單、套用模式與錯誤呈現。
- `EditorViewModel` 只接收已解析的 `PresetDocument`／`AdjustmentPatch`；不得直接碰 XML。

### 4.2 依賴方向

```text
RawProcessingCore
       ↑
  PresetCore
       ↑
PhotoLibraryCore
       ↑
 LumaHarborApp
```

不得讓 `RawProcessingCore` 反向依賴 Preset 或檔案儲存層。

## 5. 原生資料模型

### 5.1 PresetDocument

原生檔案副檔名為 `.lhpreset`，內容是 UTF-8 JSON。第一版 schema：

```swift
public struct PresetDocument: Codable, Equatable, Sendable, Identifiable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: UUID
    public var name: String
    public var groupPath: [String]
    public var isFavorite: Bool
    public var createdAt: Date
    public var modifiedAt: Date
    public var source: PresetSource
    public var patch: AdjustmentPatch
    public var xmpEnvelope: XMPEnvelope?
}
```

`name` 去除首尾空白後必須非空，顯示長度上限 120 個 extended grapheme clusters；`groupPath` 每段套用相同規則，最多 8 層。UUID 是身份，名稱不是身份。

### 5.2 AdjustmentPatch

Preset 必須能區分：

- 欄位不存在：合併套用時保持照片現值。
- 欄位存在且值等於預設：刻意把該欄位重設成預設。

因此不能拿一份完整 `PhotoAdjustments` 當 Preset。`AdjustmentPatch` 由各組 typed optional patch 組成，包含目前所有 basic、tone curve、HSL、split toning、sharpening、noise reduction、vignette 與 grain 欄位。每個 leaf 都可獨立存在。

```swift
public struct AdjustmentPatch: Codable, Equatable, Sendable {
    public var basic: BasicAdjustmentPatch?
    public var advancedToneCurve: AdvancedToneCurve?
    public var hsl: HSLAdjustmentPatch?
    public var splitToning: SplitToningPatch?
    public var sharpening: SharpeningPatch?
    public var noiseReduction: NoiseReductionPatch?
    public var vignette: VignettePatch?
    public var grain: GrainPatch?
}
```

所有 nested patch 在沒有任何 leaf 時必須 canonicalize 成 `nil`，避免兩種空值表示。

### 5.3 套用語意

```swift
public enum PresetApplicationMode: String, Codable, Sendable {
    case merge
    case replace
}
```

- `merge`：從目前 `PhotoAdjustments` 開始，只覆蓋 patch 明確存在的 leaf。
- `replace`：從 `.neutral` 開始，再套用 patch。
- 兩種模式都只處理 LumaHarbor 已支援且允許套用的欄位；opaque XMP 永不直接進 render state。
- 白平衡等需要照片 baseline 的欄位，透過 `PresetApplicationContext` 在套用時計算。
- 一次套用不論包含多少 leaf，都只呼叫 history 一次，形成單筆 Undo。
- hover／鍵盤移動產生的 preview 是 transient state：不可 autosave、不可改變 Undo／Redo、不可改變 dirty state；游標離開或取消時恢復原 render state。

## 6. XMP 表示與安全邊界

### 6.1 XMPEnvelope

```swift
public struct XMPEnvelope: Codable, Equatable, Sendable {
    public var originalPacketUTF8: String
    public var documentKind: XMPDocumentKind
    public var processVersion: String?
    public var mappedProperties: Set<XMPPropertyID>
    public var diagnostics: [XMPDiagnostic]
}
```

原始 packet 是 round-trip 與日後升級的依據。解析器另建 typed property graph，辨識 RDF scalar、array、structure、qualifier 與 namespace URI。匯出時以原始 packet 的語意樹為基底，只更新已由使用者修改且存在反向 converter 的欄位。

「無損」指 XMP 語意、namespace URI、property、型別、陣列順序、structure 與 qualifier 不遺失；不保證空白、屬性排列、quote 形式或 namespace prefix 字面值逐 byte 相同。

### 6.2 安全限制

- 單一 XMP／`.lhpreset` 預設上限 10 MiB；超過即拒絕並提供可理解錯誤。
- 禁止 `DOCTYPE`、外部 entity、網路與本機檔案 entity resolution。
- XML 最大深度 64、property 總數 20,000、單一文字值 1 MiB。
- JSON／XML 非有限數值、型別錯誤、重複衝突、非法 UTF-8 都不得 crash。
- 錯誤與 telemetry 不記錄完整私人絕對路徑，也不輸出原始 XMP 內容。
- parser 與檔案 I/O 不得在 main actor 執行。

## 7. Mapping Registry 與支援分級

Mapping key 必須至少包含 namespace URI、property local name 與 process version family：

```swift
public enum XMPCompatibilityLevel: String, Codable, Sendable {
    case native
    case approximate
    case preserved
}
```

- `native`：可可靠轉成 LumaHarbor 語意、可編輯並可反向輸出。
- `approximate`：可以套用，但演算法不同；匯入摘要要標示，且必須有固定 fixture 的視覺容差測試。
- `preserved`：保留但不套用、不顯示為已支援。

初始分類：

| 類別 | 欄位／功能 | 規則 |
|---|---|---|
| native | Exposure、Saturation、Vibrance、八色 HSL、可確認語意一致的 Tone Curve／Split Toning | 逐欄位 converter 與 round-trip 測試 |
| contextual | Temperature／Tint | Adobe 絕對值與 LumaHarbor 相對 as-shot baseline 間須在套用時換算 |
| approximate | Contrast、Highlights、Shadows、Whites、Blacks、Vignette、Grain 等同名但不同演算法效果 | 預設勾選、顯示標記、可在匯入確認時取消 |
| preserved | Crop／Rotate、local masks、AI masks、camera profile、lens correction 等尚無管線者 | 不套用，只保存 |
| preserved | Sharpening.detail／masking | 目前 model 能存，但 pipeline 未渲染，不能宣稱相容 |
| preserved | 獨立 luminance／color noise reduction 語意 | 現行 pipeline 會把兩組數值平均到單一 filter，不能宣稱獨立支援 |

規則：

- 名稱相似不等於語意相同；沒有 converter 就是 `preserved`。
- 不認識的 process version 不猜測，保留並警告。
- 超範圍原值保留；不得只 clamp 後丟失原值。
- 同一語意由多個 process-version 欄位表達時，mapping table 必須定義優先序並輸出 diagnostic。
- approximate 預設參與 patch，使用者可在匯入確認畫面取消；preserved 永不參與 patch。
- 未修改的已辨識欄位可沿用原始語意值；由 LumaHarbor 修改過的欄位才使用反向 converter 重新輸出。
- 只有單向 converter 的欄位在匯出摘要中必須標警告。

## 8. 儲存與身份

### 8.1 位置

- 我的 Preset：以 `FileManager` 的 user Application Support directory 為根，使用 `LumaHarbor/Presets/`；不得硬編使用者名稱或絕對路徑。
- 此照片庫的 Preset：`<library-root>/.lumaharbor/presets/`。
- 兩者都使用 atomic replace；不得留下半寫檔。
- 照片庫唯讀時仍可讀取及套用 library preset，但建立、刪除、改名與複製進該 scope 必須顯示可行下一步。

### 8.2 衝突

- 同 UUID 且 canonical content 相同：視為重複，略過。
- 同 UUID 但內容不同：要求選擇取代、保留兩份或取消；保留兩份時產生新 UUID。
- 同名但不同 UUID：允許共存，UI 顯示 scope／group；匯入批次可選擇自動加後綴。
- 檔名不是身份；實際檔名採 UUID，改名不移動 identity。
- 搬移 scope 是 copy-then-verify-then-delete；若來源刪除失敗，結果為已複製並警告，不能回報完整搬移成功。

## 9. UI 與工作流程

### 9.1 Preset browser

編輯器 inspector 新增可收合的 Preset 區：

- 搜尋名稱與 group path。
- 篩選「全部／我的／此照片庫／收藏」。
- 顯示群組、相容性 badge 與來源。
- hover 或鍵盤選取只做 transient preview；點擊才依目前的 merge／replace 模式套用。
- Preview render 使用既有 scheduler／throttle；快速移動時只保留最後一個 request。
- 套用、建立、匯入、改名、收藏、複製 scope、匯出、刪除都有鍵盤可達入口與 VoiceOver label。

### 9.2 建立 Preset

- 從目前照片開啟建立 sheet。
- 預設勾選與 `.neutral` 不同的 leaf；使用者可另外勾選目前為預設值的 leaf。
- 必填名稱；可選 group、scope、favorite。
- 儲存前顯示實際包含欄位數。
- 建立只寫 Preset，不改照片調整或 Undo history。

### 9.3 匯入開發預設

- 支援單一 `.xmp`、多選 `.xmp`、含 `.xmp` 的資料夾；壓縮檔不納入第一階段。
- 先解析成 preview summary，不立刻寫入 repository。
- 摘要列出成功、警告、拒絕，以及 native／approximate／preserved 數量。
- 使用者可取消 approximate leaf；確認後才寫入選定 scope。
- 部分檔案失敗不應阻止其餘檔案，但最後結果必須逐檔可追蹤。

### 9.4 匯出

- 原生 Preset 可匯出 `.lhpreset` 或 `.xmp`。
- 沒有 XMP 反向對應的 leaf 在匯出前列出；使用者可繼續，但不能顯示「完整相容」。
- 從 XMP 匯入的 Preset 匯出時保留 unknown／preserved property。
- 目的檔已存在時使用系統 save panel 的取代確認，不自行靜默覆寫。

## 10. 第二階段：相鄰照片 XMP 搬家

### 10.1 Discovery

- 對可支援的 RAW，檢查同目錄、同 basename、大小寫不敏感副檔名 `.xmp`。
- discovery 只讀取必要 metadata；完整解析在背景 bounded concurrency 執行。
- DNG 內嵌 XMP 不在本階段，不得宣稱已掃描。
- 每份候選記錄 source fingerprint，已確認且內容未變者不重複提示；內容變更後可重新列入摘要。

### 10.2 確認與寫入

- 摘要顯示候選照片數、可完整映射、含 approximate、含 preserved、拒絕及既有 LumaHarbor edit 衝突數。
- 使用者必須明確確認；取消時零寫入。
- 沒有既有 LumaHarbor edit：把可套用 patch 轉成 `PhotoAdjustments` 並寫入既有 `PhotoSidecar`。
- 已有 LumaHarbor edit：逐照片選擇略過、merge 或 replace；批次預設為略過，避免覆蓋現有成果。
- unknown XMP envelope 必須有可攜帶的 LumaHarbor 儲存位置；需要 bump `PhotoSidecar` schema 時，舊 schema 必須仍可讀，新欄位缺失有安全預設。
- 每一張照片獨立 atomic write；批次結果可部分成功，但必須列出成功／略過／失敗，不得整批偽裝成成功。
- 絕不改寫或刪除原始 Adobe XMP。匯出回 XMP 必須是另一個明確操作。

## 11. 錯誤模型

至少區分：

- unsupported document kind
- malformed XML／JSON
- unsafe XML construct
- unsupported future native schema
- unknown process version
- no applicable adjustments
- read-only destination
- destination unavailable
- identity conflict
- partial batch failure
- reverse mapping unavailable

每個使用者可見錯誤都包含：發生什麼、哪些資料沒有被改動、下一步。debug log 可用安全代號與 basename，但不得輸出私人絕對路徑或完整 XMP packet。

## 12. 測試策略

### 12.1 純模型與 codec

- 每個 optional leaf 的 absent／explicit-default 區別。
- merge／replace 的 table-driven 測試，含 nested patch。
- 原生 schema round-trip、future schema 拒絕、缺欄位預設。
- XMP scalar、array、structure、qualifier、namespace 與 unknown property round-trip。
- semantic-equivalence comparator，不以 byte equality 判定 XMP round-trip。
- DOCTYPE／entity、深度、大小、property 數與文字長度限制。
- 非有限數值、超範圍數值、重複／衝突欄位。
- 每個 mapping 的正向、反向、process version 與 compatibility level。

### 12.2 真實相容 fixture

- 建立可提交、已去除私人 metadata 的小型 XMP fixture corpus。
- fixture 至少包含：subset preset、完整 basic／HSL／curve、舊與新 process version、unknown namespace、nested RDF、Unicode 名稱、corrupt、oversized synthetic boundary。
- fixture 必須記錄產生工具與版本；至少以當時可用的 Lightroom Classic 與 Adobe Camera Raw 實際匯入／匯出各驗證一次。
- 不提交私人照片、完整私人路徑、Adobe 帳號資料或序號。

### 12.3 影像與整合

- 對 native／approximate mapping 使用固定 RAW fixture 建立 render comparison；容差要針對各調整定義，不以一個寬鬆全域門檻掩蓋差異。
- hover preview 取消後畫面、dirty state、autosave 與 Undo history 完全恢復。
- 點擊套用一個複合 Preset 後一次 Undo 完整復原，一次 Redo 完整重做。
- APFS 與真實 exFAT 上驗證 library preset 建立、讀取、改名、搬移、唯讀與拔除情境。
- 批次 XMP 搬家測試取消零寫入、衝突預設略過、部分失敗、重跑冪等與原 XMP 未變。

## 13. 階段驗收

### Gate A：原生 Preset 核心

- `.lhpreset` schema、repository、兩種 scope、建立／管理、merge／replace 與單筆 Undo 全部有測試。
- transient preview 不寫檔、不污染 history。

### Gate B：開發預設 XMP

- fixture corpus 的匯入、unknown 保存、語意 round-trip、相容性摘要與匯出全部通過。
- 實際 Adobe 工具 smoke test 有版本與結果記錄。
- 惡意／損壞 XML 不 crash、不讀取外部資源、不洩漏路徑。

### Gate C：照片 sidecar 搬家

- discovery、確認、衝突、partial failure、冪等與零改動取消通過。
- `.lumaharbor` 保持唯一主來源，原 Adobe XMP 未被改寫。

### Gate D：完整回歸

- `swift build -Xswiftc -strict-concurrency=complete` 通過且無新增 warning。
- `swift test -Xswiftc -strict-concurrency=complete` 全部通過。
- 設定私人 RAW fixture 後，`RawFixtureTests` 全部通過。
- `Scripts/run-mvp-acceptance.zsh --preflight-only` 與完整 runner 通過。
- `git diff --check` 通過；沒有加入私人 fixture、私人路徑或無關檔案。

## 14. 實作與交接規則

- 第一、第二階段使用分開的 implementation plan 與 commits；每個可審查 task 保持獨立 commit。
- 採 TDD：先看到針對需求的測試失敗，再做最小實作使其通過。
- Claude Code 修改時，Codex 不得同時修改相同 worktree；Codex 只在 Claude 完成交接後 review。
- 不處理 `docs/reference/`，不得 add、commit、stash、修改或刪除該目錄。
- 不 force push；完成後先 fetch 並確認 remote 狀態，再依使用者授權決定是否 push。
- 若完整驗收因外接 exFAT 未掛載而無法執行，必須明確回報，不能假造、略過或把 SKIPPED 當 PASS。

