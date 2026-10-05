# LumaHarbor 主線整合規格：白平衡、數值輸入與調整筆刷

- 日期：2026-10-05（Asia/Taipei）
- 任務識別：`LH-MAIN-INTEGRATION-20261005`
- 版本：v1.0
- 狀態：`SPEC ONLY`；尚未建立整合工作樹、修改產品或執行本規格的驗收。
- 目標：以最新 `origin/main` 為唯一產品基準，移入已開發的白平衡／數值輸入／iPad 滴管修正與 Brush Mask v1，保留主線既有功能和資料，交付可獨立驗證的整合候選。
- 本次授權範圍：撰寫整合規格。建立產品 branch/worktree、實作、提交、推送、合併及安裝 App 均未在本輪執行；本文描述後續工作，不代替操作授權。

## 1. 文件位置與依據

本文件位於 TARGET repository 的 `docs/superpowers/specs/`；SOURCE 的外部工作樹只以 `SOURCE` 別名引用，不得把外層目錄當成產品 repository，或把整個外層目錄加入產品 Git。

以下使用三個別名；產品路徑均相對於各自 Git root：

| 別名 | 意義 |
| --- | --- |
| `MAIN` | 遠端 `origin/main` 的正式產品 tree；由 `git worktree list --porcelain` 定位 checkout |
| `SOURCE` | 來源工作樹；只讀取其中待移入成果 |
| `TARGET` | 後續獲准後，從當時最新 `origin/main` 建立的新整合 branch/worktree |

必要依據：

1. `MAIN/AGENTS.md`、`docs/coordination/SHARED_AGENT_READ_PROTOCOL.md`、`SHARED_GIT_WORKFLOW.md`、`CURRENT.md`、`DECISIONS.md`。
2. [白平衡與輸入第一輪規格](2026-09-29-white-balance-and-input-correctness-repair-spec.md)及[第二輪規格](2026-09-29-white-balance-and-input-review-followup-spec.md)。兩份規格的數值、狀態與 26 項驗收繼續有效。
3. SOURCE 的 `docs/superpowers/specs/2026-10-01-morrowraw-brush-mask-parity.md` 及 `docs/superpowers/specs/2026-10-02-brush-mask-review-repair-spec.md`。
4. SOURCE 的 `docs/testing/reports/2026-09-29-white-balance-and-input-review-followup.md`、`docs/testing/reports/2026-10-02-brush-mask-review-repair.md` 及 `verification/2026-10-02-luna-deliverables/report.md`。
5. `MAIN/docs/testing/reports/2026-09-19-lightroom-neutral-raw-baseline-v1.md` 與 `MAIN/docs/coordination/CURRENT.md` 的 fail-closed 整合紀錄。

本規格只取代來源規格中的「沿用 SOURCE 實作」、「sidecar schema v3」及以舊工作樹 signing failure 作為整合環境例外的安排。主線採 v5 的理由與契約見 §6。原有功能驗收不因改換主線而降低；原報告只提供歷史證據，不能標記 TARGET 的測試通過。

## 2. 已核對的起點

2026-10-05 已執行本機 Git 與 `git ls-remote --heads origin` 核對；這是本規格撰寫時的快照，實作前必須重查。

| 項目 | 快照 |
| --- | --- |
| `MAIN` HEAD／遠端 main | `82542e73aae8f16b0ba7e4d9d36a8a42451a7319`；工作樹乾淨 |
| MAIN 最近驗證產品基準 | `2905314872686aa836848ebe27a8e82cddfee658`；之後至 HEAD 只有 `docs/coordination/CURRENT.md` 差異 |
| SOURCE branch／HEAD | `codex/open-source-release-prep`／`5a80e969fbae94d8ee6db4842f3a2def781329f3` |
| 已推送的白平衡成果 | `origin/codex/white-balance-ipad-fixes-20261001` 與 SOURCE HEAD 相同；主要產品提交 `d9041d7` |
| SOURCE 工作樹 | 24 個 tracked modified、10 個 untracked，共 34 個路徑；新筆刷與修正仍在未提交內容中 |
| 既有個人設定 | `Apps/LumaHarborPad.xcodeproj/project.pbxproj` 有 local-only signing 差異，禁止移入 |
| Git 歷史 | repository 非 shallow；`git merge-base origin/main SOURCE_HEAD` exit 1，無共同祖先；兩個 committed trees 相差 378 個檔案，不含未提交筆刷 |
| 同名舊遠端 branch | `origin/codex/open-source-release-prep` 是另一份歷史，不能拿它的 tracking ahead/behind 判斷此次整合 |

最近報告中的測試數字：MAIN 完整 suite 2574 executed／17 skipped／0 failure；SOURCE 筆刷修正後完整 suite 2051 executed／12 skipped／1 signing failure，focused 53/53、probe 7/7、RAW 11/11。這些測試本輪未重新執行，也不是不同測試數量代表功能優劣的證據。

## 3. 整合策略與範圍

### 3.1 選定策略

採用 **MAIN 上的逐項行為移植**。TARGET 從最新 main 建立，對每一項來源能力先建立主線上的失敗回歸，再適配來源實作，最後驗證主線既有功能。

不採整個 SOURCE tree 覆蓋或 `--allow-unrelated-histories` 合併：SOURCE 缺少主線的部分專業編輯、recipe、Sidecar v4、發布與共用 UI 架構。也不直接 cherry-pick 整個 `d9041d7`：它跨 67 個檔案，包含舊版 Inspector／Filmstrip／pipeline 的修改，必須按接點判斷。

不從主線重新設計另一套筆刷：來源模型和缺陷反例可重用，但來源測試通過不代表適配後已正確。

### 3.2 本輪包含

- WB：baseline-aware 白平衡解析、滴管 Tint 方向、decoder 最後防線、有限 legacy 白平衡保存、新提交合法化與 preset 能力診斷。
- INPUT：Mac／iPad 原生欄位草稿、精度、Enter／blur／Escape、同值外部更新、增減與重設一致性。
- SESSION：photo／revision／frame 綁定，拒絕過期候選與晚到渲染，真正影像和 histogram 還原。
- PAD：在主線既有 Inspector／canvas composition 接入滴管入口與手勢；必要的 44 pt 命中區及窄欄排版修正。
- BRUSH：獨立 `brushMasks`、四項缺陷修正、座標映射、單次提交、預覽／匯出、Local opt-in 複製貼上及快照整合。
- DATA：Sidecar v5、兩種筆刷共存、主線 curation／snapshots／unknown top-level fields 的保存、失敗與回退保護。

### 3.3 非目標

不開啟 Adobe renderer，不新增 production profile registry，不宣稱 Lightroom 校色完成；不改主線 Inspector 整體設計，不整批搬回來源 portrait sheet 或 Filmstrip 樣式；不新增 iPhone、修復演算法、AI 遮罩、筆刷 preset、筆刷 XMP 映射、跨遮罩任意排序或舊筆刷自動轉換；不清理舊 branch/worktree，不操作日常圖庫，不同步／安裝日常 App。

主線已有的上述功能仍須保存；「不新增」不構成移除授權。

## 4. 基準、來源保全與寫入範圍

1. 實作開始前，核對 MAIN 遠端 SHA、SOURCE HEAD、34 項清單與所有相關 diff。若 main 或來源改變，先更新基準及差異清單，不沿用本文件數字當作已確認。
2. TARGET 必須是單一寫入者的新 branch/worktree，建議名稱 `codex/mainline-wb-brush-integration`；建立動作須符合當次使用者授權及主線協作規則。
3. SOURCE 保持唯讀。P0 建立 repo 外的本機來源快照，涵蓋已提交來源、tracked diff、**全部相關 untracked 程式／測試／文件**；單靠 `git diff` 不足以保存新檔。
4. 快照清單記錄相對路徑、狀態、SHA-256、來源 HEAD、採用理由及排除理由；複製前後檔案 hash 必須一致。來源有 writer 時先完成所有權交接，不能複製出混合 revision。
5. signing 檔僅在本機核對未被修改，內容不複製入公開文件或 TARGET。來源既有測試／報告保留，不以修正後結果覆寫歷史 FAIL。
6. 禁止整檔覆蓋 MAIN 的 `PhotoAdjustments`、`PhotoSidecar`、`EditorSession`、render pipeline、`PadEditorView`、`LocalAdjustmentsPanel`、`AGENTS.md`、`Package.swift` 或 Xcode project；逐項合併必要能力。
7. 新整合分支的 diff 只能包含本規格範圍。`CURRENT.md` 記錄 TARGET 的 owner／base／HEAD／gate，不把 SOURCE 的歷史正文整份搬成新主線狀態。

來源快照保全與 TARGET 實作相互獨立。不得 reset、stash、checkout 還原、刪除來源內容，或使用來源 signing 設定來讓測試／建置通過。

## 5. 主線不可退化的能力

| 主線能力 | 整合後必要結果 |
| --- | --- |
| Curation | 評分、旗標、關鍵字、時間語意及 sidecar 權威性保留；無關調整不改 curation |
| Snapshots | 名稱、ID、時間、完整調整保存；建立／還原／刪除／重開／比較皆正常，含新筆刷；還原一筆 compound Undo |
| 專業調光 | 四通道曲線、Presence、Color Grading、monochrome、app profile、lens、parametric curve 不因 model copy/clamp/reset 消失 |
| 既有局部調整 | gradient、radial、舊 brush、range、subject/background、heal/clone/red-eye 保留資料、渲染與入口 |
| RAW recipe | persisted/requested policy、effective Native、camera profile request、diagnostics、color space、preview/export parity 保留 |
| 專業預覽 | clipping、gamut warning、soft proof、snapshot compare 仍在既有預覽層；不燒入最終匯出 |
| iPad 工作區 | 保留主線已拆分的 model/canvas/inspector/container/coordinator，避免重引入來源巨型 view 與雙份 inspector 行為 |
| 圖庫與批次 | 多來源離線／重連、來源身分、atomic write、batch undo conflict guard、虛擬副本不退化 |
| 發布 | semantic version、兩平台版本同步、atomic publication、資源封裝與 privacy scan 保留 |

每項有明確比較基準與測試。新增欄位須檢查 `PhotoAdjustments` 的 initializer、Codable、`clamped()`、neutral/reset、copy/patch、快照與 history；不能只把 property 加進 struct。

## 6. 資料設計與版本政策

### 6.1 Sidecar v5

- `PhotoSidecar.currentSchemaVersion` 升為 **5**；保留 v3 的 curation、v4 的 snapshots，新增 `adjustments.brushMasks` 語意。不能照搬 SOURCE 的 v3 或維持 v4 後依賴舊 reader 忽略新欄位。
- 讀取支援 v1～v5。缺 `brushMasks` 為空；v1/v2 缺 curation、v1～v3 缺 snapshots，沿用相應舊資料政策。
- 新 sidecar，以及使用者有效編輯／保存造成的寫入，輸出 v5。儲存既有 sidecar 時在共用保存邊界升版，不只修改 initializer；所有 Mac、iPad、批次、快照與 curation-only writer 遵守。
- 單純載入、預覽、選取、取消或 no-op 操作，不因本輪版本／白平衡／筆刷新增寫回。既有 v1/v2 SQLite curation 遷移是明確例外，保留其既有觸發與 retry 契約，成功寫入時採 v5。
- v6 以上先分類為 unsupported，保留原 bytes／位置，不 quarantine、不解成 neutral、不 autosave。直接 write、autosave、curation、snapshot 等入口不能覆寫不支援格式。
- 用 MAIN 的 v4 reader 實際讀取有效 v5：必須報 newer schema，不能改 RAW 或 sidecar。回退 App 後，新檔只能由支援 v5 的版本繼續編輯；不得降成 v4 並丟棄筆刷。

### 6.2 來源實驗 v3 的相容性

SOURCE 的 v3 不是主線 v3 的完整資料模型。讀取其合法 `brushMasks`，保留 renderer version、ID、順序與精確值；缺少主線欄位時套用 MAIN 的缺值規則，不把存在的 curation／snapshots 當未知資料丟掉。

若 v3 JSON 含 `adjustments.brushMasks` 且沒有 `curation` key，將其視為可識別的實驗來源：缺少 curation 不能等同使用者已明確設成 neutral。保留欄位存在性資訊；已有 SQLite curation 時可作為記憶體顯示來源，但不因掃描實驗來源新增自動升版／寫回。下一次使用者有效保存時才合併並寫 v5。

未知 renderer version 或非法 brush patch 走明確錯誤／既有可復原隔離流程，禁止忽略筆刷後保存。已知舊實作可能把 geometry display 點誤存成 source 點，無法由目前 geometry 推算原意；不自動反轉、猜測或遷移。實驗檔匯入測試須揭露此限制。

### 6.3 兩個已辨識的保存接點

**Curation 門檻：**MAIN 的 `Service/CurationMigration.swift` 現以 `schemaVersion >= PhotoSidecar.currentSchemaVersion` 判斷 sidecar 權威。升到 v5 後，不能把有 curation 的 v3/v4 誤視為待 SQLite 覆蓋的 legacy。判斷必須依「curation 自 v3 引入」及必要的欄位存在性，不依最新 schema。測試同時涵蓋非 neutral 與明確 neutral sidecar 對抗過期 SQLite 值。

**快照刪除：**MAIN 的 `Sidecar/SidecarRepository.swift` 保存 unknown top-level fields 時，`knownKeys` 尚未包含 `snapshots`，而 encoder 對空快照陣列省略該 key。整合需驗證並修正「刪除最後一張快照→寫入→重開」不從舊 JSON 恢復快照。已知 key 清單須涵蓋所有產品自有 top-level keys；真正未知的 top-level keys 仍保留。

以上為此次資料整合的必要適配，不擴大重寫整個儲存層。無損比較以 decoded 值與 JSON 欄位為準；允許 canonical JSON 格式變更，但沒有寫入意圖時 bytes／mtime 必須不變。

## 7. 兩種筆刷、渲染與座標

### 7.1 共存契約

- MAIN 的 `LocalAdjustmentKind.brush`／`LocalAdjustmentGeometry.brushStrokes` 保留；其 points、pressure、radius、feather、opacity、inversion 與舊渲染位置不得被新模型重新解釋。
- 新 `PhotoAdjustments.brushMasks` 為獨立有序陣列，使用來源 `BrushMask`／`BrushMaskStroke`／`BrushMaskPath` 語意，rendererVersion 維持 1。
- 既有 `EditorToolMode.brush` 繼續對應舊 local mask；新模式使用獨立識別，例如 `.brushMask`。選取 ID 必須連同模型種類識別，不可用同一裸 UUID 在兩個陣列間猜測。
- Local inspector 保留主線既有局部遮罩入口，增加「調整筆刷」區域及新建入口；新筆刷提供 paint/erase、size/feather/flow/density、曝光、enable/select/delete。兩組清單不可跨組重排，也不自動轉換舊筆刷。
- 同張照片可同時含兩種筆刷，兩者只各渲染一次。切換工具會取消另一個進行中的 gesture，但不刪除已提交內容。

### 7.2 必須保留的渲染順序

```text
MAIN recipe resolver／effective Native decode／global adjustments
  → 新 BrushMaskRenderer（source coordinates）
  → MAIN GeometryRenderer
  → MAIN LocalAdjustmentRenderer（含舊筆刷與其他既有遮罩）
  → preview-only professional preview options
  → MAIN color-managed display

export 使用相同前四階段，接既有尺寸／色域／編碼流程；不加入 preview-only 標記。
```

在 MAIN 的 `CoreImagePreviewRenderer` 與 `PhotoExporter` 接入筆刷階段，保留 resolver、lens correction、camera-profile request、decode result recipe、render-service color configuration。來源 renderer 缺少這些主線參數，禁止整檔替換。

新白平衡 resolver 必須供同一 recipe/decode 路徑使用；不可用移除 recipe、改回舊 native-only request 的方式達成欄位一致。`PreviewImage` 同時保存既有 `rawRenderRecipe`、baseline 和新增 brush mapping，並與實際像素同 revision 發佈。

### 7.3 筆刷四項修正與幾何矩陣

1. BR-F01：左上來源座標到 Core Image extent 方向正確；非中央位置、非方形、非零 extent、四象限與 erase 均測實際遮罩／像素。
2. BR-F02：view→display→source 使用真實 geometry inverse；orientation、flip、quarter-turn、crop、straighten、perspective 與主線 renderer 共用權威變換。不可逆、圖外、透明區或無可信 metadata 時拒絕；不 fallback identity、不 clamp pointer 到邊界。
3. BR-F03：相同折線插入共線點，固定弧長 sample 數量／位置／順序不變；間距保留 `max(size/8, 1/shortSide)`，sample tolerance `1e-9`，另以低 flow／非零 feather 的實際遮罩驗證。
4. BR-F04：九個 patch 欄位依 `AdjustmentCatalog` 的權威範圍，在 decoder、encoder、validated 及提交／保存邊界驗證。nil／合法端點保真，越界／非有限值拒絕；不改普通 legacy local patch 的相容性。

完整測試沿用筆刷修正規格 §5：identity、H/V/H+V、90/180/270、非中央 crop、straighten ±10°、perspective H/V ±25、兩組組合，以及 0.75×/1×/2× view zoom、resize、iPad 直橫向。另用非對稱 landmark image 作獨立像素 oracle，不能只用 mapper 自己 round trip 證明 renderer 正確。

連續座標 round trip 誤差 ≤來源短邊 `1e-6`；落點 ≤1 output pixel；同尺寸未改區域通道誤差 ≤`1/255`。preview/full-resolution 先對齊 source landmarks，再分中心、遮罩外及 feather 邊界量測；不能宣稱不同解析度 byte-identical。

游標與已存 path 使用同一 forward mapping 和 source 短邊尺寸；不固定乘畫布寬度。MAIN 有、SOURCE 沒有的幾何能力亦須納入 mapper，不能移入 SOURCE mapper 後關閉主線透視或 corner-pin 能力。

## 8. 白平衡、輸入與手勢

### 8.1 白平衡

- 保留 `45 K / stored temperature unit`、stored 範圍 `[-1200,1200]`、產品 Kelvin 範圍 `[2000,50000]`。baseline B 有效時，合法新 offset 為兩範圍的交集：`[-1200,1200] ∩ [(2000-B)/45,(50000-B)/45]`。
- 純 Double 往返誤差 ≤`1e-6 K`，decoder Float 誤差 ≤`0.01 K`；UI 整數顯示可以捨入，但不得以顯示值覆寫精確模型。
- baseline 缺失／無效不猜 5500 K；需要 baseline 的新操作明確不可用並解釋原因。decoder 防止非法非零修改進入 native filter。
- 有限 legacy 越界 offset 保存原值；預覽／匯出用受限有效值及診斷。載入、Undo、redo、無關編輯與 snapshot 往返不偷偷正規化；只有使用者明確改白平衡才寫入新的合法值。
- 新滴管偏綠產生正 Tint，偏洋紅產生負 Tint；不反轉既有 stored Tint、局部 Tint 或舊 preset。native preset 與 XMP capability/diagnostics 依主線 profile 政策保留。
- 受控 RAW 四色偏與灰卡誤差驗收沿用原規格；缺素材仍 NOT RUN，不用數值方向測試冒充校色完成。

### 8.2 輸入生命週期

有效 Enter＋blur 共一次提交；Escape／未修改草稿／無效輸入零提交。`6500 → 60000 → Enter → blur` 必須回復可見 6500 並保留範圍說明；`4536.72802734375` 只聚焦再離開，不量化成 4537。

照片、revision、同值 reset、preset、Undo/Redo 使舊草稿失效；需同步真正 AppKit/UIKit 可見欄位，而非只有 SwiftUI binding。± 與重設保留主線步距、邊界、44 pt、八語系和 accessibility。文字欄、滑桿、照片、sidecar 使用同一權威值。

### 8.3 共用 session／frame

press 固定 photo ID、session identity、權威 edit revision、frame/mapping、settings。move 只 transient preview；有效 release 一筆 history／一次保存意圖。空筆刷新建只進入工具，不建立已保存空 mask。

換照片（含 A→B→A）、取消、改 geometry、Undo/Redo、restore snapshot、preset、batch 更新或切換 compare，使舊 gesture／候選失效；晚到 release 不得新增寫入。圖外再返回切 path；滴管有效→無效→release 不得提交上次有效候選。

render／histogram／error 在 actor hop 前攜帶 intent identity；舊回應不得覆蓋新意圖。拒絕取樣保留診斷；重新取樣中性時真正 displayedImage 和全部 histogram bins 回復，不能只比較 `displayedAdjustments`。

iPad 接線使用 MAIN `PadEditorCanvasView`、`PadInspectorHost` 及 coordinator；不照搬 SOURCE 的雙 host。工具啟用時採與 frame 一致的可編輯顯示，compare/zoom 行為明確，禁止依錯畫布接收手勢。

## 9. 快照、複製貼上與重開

- 快照的 `PhotoAdjustments` 同時含新舊筆刷；建立、還原、比較、Undo/Redo、保存後重開不丟 main-only 欄位。快照比較也必須走包含新筆刷的產品 renderer。
- 「Include Local Adjustments」關閉：目標的 `localAdjustments` 與 `brushMasks` 都保留；開啟：兩個陣列都按來源內容替換，空來源清空對應內容，nil 表示未選取而不是清空。
- Mac／iPad 相同語意。跨照片複製保留 normalized source points，目標使用自己的 geometry mapping；不得把來源畫布 display 座標寫入目標。
- batch Undo 沿用主線「不覆寫同步後使用者再修改的欄位」保護；新舊筆刷作為各自 field group 參與衝突判斷。clipboard 不攜帶照片 ID、curation、snapshots、來源路徑或權限資訊。
- preset／XMP 不新增筆刷交換格式；不含局部編輯的 preset 應保存現有筆刷，依原有 scope/reset 語意測試，不因重建 PhotoAdjustments 默默清空。
- Mac 圖庫、iPad app-copy、iPad in-place／外接來源皆測有效 stroke→autosave 完成→關閉→重建 repository/session→重開。只呼叫 `saveAdjustments` 不算 UI autosave 驗收。
- 原 RAW bytes、fingerprint 和 metadata 不因編輯而改寫。保存失敗／離線要顯示既有可恢復狀態，不能假稱已保存或覆寫其他來源。

## 10. 適配接點

以下是檔案責任，不是整檔複製清單；實作前確認目前主線位置。

| 接點（TARGET 相對路徑） | 適配責任 |
| --- | --- |
| `Sources/RawProcessingCore/Model/PhotoAdjustments.swift` | 加 brushMasks，保留全部主線欄位、legacy WB、reset/clamp/copy/Codable |
| `Sources/RawProcessingCore/Model/WhiteBalancePresentation.swift`、`WhiteBalanceEyedropper.swift`、`AdjustmentMapping.swift` | 移入 resolver／能力與方向修正；新檔依 TARGET 現況新增 |
| `Sources/RawProcessingCore/Model/BrushMask.swift`、`BrushCoordinateMapping.swift` | 新筆刷資料與合法性、主線 geometry mapper |
| `Sources/RawProcessingCore/Pipeline/BrushMaskRenderer.swift`、`GeometryRenderer.swift` | 筆刷方向／coverage；共享幾何而不改既有像素 |
| `Sources/RawProcessingCore/Decoding/`、`Preview/`、`Export/PhotoExporter.swift` | 在 MAIN recipe 中接入 WB／brush／frame，保留 Native fallback |
| `Sources/PhotoLibraryCore/Sidecar/PhotoSidecar.swift`、`SidecarRepository.swift` | v5、版本預檢、所有 writer、unknown keys 與 snapshot 清空 |
| `Sources/PhotoLibraryCore/Service/CurationMigration.swift`、`PhotoLibraryService.swift`、`Documents/PhotoDocumentStore.swift` | curation 門檻／來源存在性、讀寫／升版／回退一致 |
| `Sources/EditorCore/EditorSession.swift`、`EditorToolMode.swift` | session identity、候選失效、新舊模式、snapshot/batch/history |
| `Sources/AdjustmentUI/Adjustment*Input*.swift`、`AdjustmentNativeTextField.swift`、`BasicAdjustmentPanel.swift` | 原生輸入狀態與 WB 語意，保留主線 panel 欄位 |
| `Sources/AdjustmentUI/BrushMaskOverlayView.swift`、`LocalAdjustmentsPanel.swift`、`PadAdjustmentClipboard.swift` | 新舊筆刷共存、geometry/gesture、Local opt-in |
| `Sources/LumaHarborApp/Views/EditorView.swift`、`Views/EyedropperOverlayView.swift`、`ViewModels/LibraryViewModel.swift`、`Models/AdjustmentClipboard.swift` | Mac 接線、autosave／批次回復，不搬舊 Inspector 外觀 |
| `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorCanvasView.swift`、`PadEditorModel.swift`、`PadInspectorHost.swift`、`PadInspectorCoordinator.swift` | 依主線拆分架構接入，不還原舊單檔實作 |
| `Sources/PresetCore/Application/PresetApplicator.swift`、`Sources/Localization/Resources/` | baseline 能力、既有 preset scope、八語系必要文案 |

禁止為測試方便縮減主線套件、移除原有 test target、改低期望值或把已知失敗直接 skip。必要的小型抽取只服務本文的共用規則與測試性。

## 11. 階段與交付界線

| 階段 | 工作與可審查交付 | 依賴／退出條件 |
| --- | --- | --- |
| P0 基準 | MAIN／SOURCE manifest、本機唯讀快照、TARGET 基準測試、逐項採用／適配／排除清單 | 來源穩定，TARGET 起點可追溯；無來源簽章混入 |
| P1 白平衡／輸入 | 在 MAIN recipe/session/UI 移入修正，保留主線專業欄位 | 核心與輸入回歸通過；26 項 WB 矩陣持續記錄，完整 UI／素材 gate 於 P5 閉合 |
| P2 資料 | v5、新舊模型共存、curation／snapshot 保存、舊 reader 拒絕 | DATA 模型／儲存專項通過才接 UI；snapshot compare 等渲染／端到端子項於 P3～P5 閉合 |
| P3 核心渲染 | BR-F01～04、主線 geometry／recipe 接線 | geometry／pixels／empty-brush Native 回歸通過 |
| P4 操作整合 | Mac/iPad overlay、取消與競態、clipboard、snapshot、autosave | 真正 UI／磁碟／重開行為通過，不能只驗模型 |
| P5 候選驗收 | 完整 suite、RAW、build、Mac／Simulator／真機、效能／隱私及交接 | §12 全部必要 gate 有證據才標整合 READY |

先寫失敗行為測試、確認有效控制、適配最小修改，再重跑有關 suite。基準既已具備的能力做回歸，不刻意拆壞它來湊紅燈。各階段可分別審查；只有取得相應授權才建立提交，不以「完成 P5」自動推送／合併／發布。

## 12. 驗收矩陣

**以下全部是 TARGET 的新驗收，初始狀態均為 `NOT RUN`。** 原 26 項 WB 及筆刷修正規格完整矩陣是子清單，下面交叉項目不能取代它們。

| ID | 必要證據／判定 |
| --- | --- |
| BASE-01 | fresh TARGET 源自已查證的 origin/main；來源快照包含 untracked；來源前後 HEAD／狀態／內容未被本任務改動 |
| MAIN-01 | §5 主線模型與功能全保留；含非 neutral 專業欄位的 sentinel fixture 經所有 copy/clamp/reset/preset/snapshot 路徑不失真 |
| WB-ALL | 原白平衡 26 項完整矩陣重跑，逐項列 PASS/FAIL/NOT RUN，包含真實輸入、灰卡與指定像素量測 |
| DATA-01 | MAIN v1/v2/v3/v4、SOURCE 實驗 v3、新 v5 的讀寫矩陣；curation/snapshot/兩種筆刷/unknown top-level fields 保真 |
| DATA-02 | 單純載入／取消／no-op 無新增升版；有效保存統一 v5；既有 v1/v2 curation 遷移例外具明確寫入原因 |
| DATA-03 | v3/v4 有 curation 時 sidecar 勝過衝突 SQLite，含 neutral；實驗 v3 缺 key 不錯判 neutral、不自動寫回 |
| DATA-04 | 刪除最後快照後重開仍無快照；建立／還原含新舊筆刷快照、一筆 Undo、compare 渲染正確 |
| DATA-05 | MAIN v4 reader 拒絕新 v5、TARGET 拒絕 v6；read/write/autosave/curation/snapshot 不能改原 bytes、不能把 newer schema 隔離為損壞 |
| DATA-06 | 非法九欄 patch／未知 renderer version 在真實保存邊界拒絕；合法 JSON 注入與 encoder/decoder/validated 分開驗證 |
| BRUSH-ALL | 原筆刷 FIX/GEO/GEST/DATA/PIPE 矩陣全部重跑；含完整 geometry、獨立 landmark、稀疏／密集分段像素 |
| MIX-01 | 同張圖新 brush＋舊 brush＋radial/range/heal 的獨立及組合輸出；無雙重渲染、順序漂移、選取誤路由 |
| RAW-01 | Adobe disabled＋empty production registry；requested policy/profile/diagnostics 保留，實際 decode／preview／export Native，不以 WB 操作開啟 renderer |
| RAW-02 | 同 RAW／recipe／color space 的 preview/export/單張/批次一致；空筆刷與未涉及 WB 修正的有效參數對 MAIN 無像素退化 |
| RACE-01 | gesture 中換照片／改幾何／Undo／snapshot restore／cancel 後舊 release 零額外 history／autosave；晚到 image/histogram/error 被拒絕 |
| CLIP-01 | Local off/on、空來源、新舊筆刷同時存在、異圖 geometry、Mac/iPad、batch sync 與受衝突保護的 Undo |
| STORE-01 | Mac 與 iPad app-copy/in-place 的 UI→autosave→磁碟→重開完整往返；離線／保存失敗不誤報成功，RAW 不變 |
| UI-MAC | 前景真實 TextField/滑鼠，含 Enter/blur/Escape/雙擊／±／重設、滴管、paint/erase/取消/Undo/重開與代表性既有面板 |
| UI-SIM | iPad Simulator 直橫向／窄視窗／zoom、相同輸入與畫布流程、Files 開啟；各有動作和保存證據 |
| UI-DEVICE | TARGET 同版實體 iPad 觸控、旋轉、外接來源／重開／保存；Apple Pencil、外接鍵盤、VoiceOver 分列可用性和結果，不能用 Simulator 代替 |
| REG-01 | fresh scratch 完整 swift test 零 failures；私有 RAW suite 實際執行；必要新測試不得 skipped/0 tests |
| BUILD-01 | strict-concurrency build、Mac Release、iPad generic device 與 Simulator build 通過；真機安裝／啟動另列，不混作 UI gate |
| PERF-01 | 同硬體、同素材、同 recipe 交錯比較 MAIN 與 TARGET；空筆刷及實際筆刷負載分別量測；方法見 §13 |
| PRIV-01 | diff/來源清單/待提交文字／App／解壓 ZIP 的必要隱私檢查，無 signing／私人素材／路徑混入；來源 RAW 與 local-only signing 未被改動 |

PASS 要求該列所有必要子條件通過。部分未做為 NOT RUN，已有失敗為 FAIL；framework SKIPPED 單列原因，不算 PASS。圖形控制影像失敗時記 INCONCLUSIVE 並修正環境，不能用全黑像素相等過關。

整合 READY 要求上述必要 gates 通過；缺真機或灰卡時可以交付「實作完成、驗收未完成」的候選，但不能稱整合已完成。Apple Pencil／外接鍵盤若無設備，記 NOT RUN，明確排除該輸入支援的完成宣稱；基本觸控真機 gate 仍必要。

Lightroom 正式 Gate 2 仍保留既有 FAIL／NOT RUN，不是本文的 READY 子項：此候選只允許 Native fail-closed 行為。任何啟用 Adobe renderer 的提議都需另循 Lightroom 校準規格和其完整 gate。

## 13. 驗證方法與命令

### 13.1 執行原則

在 TARGET 執行，scratch／derived-data 使用本任務新目錄。開始前先在 MAIN 的乾淨副本量測基準；不得把 SOURCE 的 signing-only failure 搬進 TARGET 當成常態例外。完整 suite 若有 failure 就標 FAIL，先診斷是否基準既有／環境／新回歸，不修改 signing 或弱化契約清除失敗。

```sh
integration_scratch=$(mktemp -d "${TASK_SCRATCH_ROOT:-.}/lumaharbor-integration-swift.XXXXXX")
integration_ios_sim=$(mktemp -d "${TASK_SCRATCH_ROOT:-.}/lumaharbor-integration-sim.XXXXXX")
integration_ios_device=$(mktemp -d "${TASK_SCRATCH_ROOT:-.}/lumaharbor-integration-device.XXXXXX")

swift test --scratch-path "$integration_scratch" --filter 'WhiteBalance|Eyedropper|AdjustmentInput|AdjustmentValueInput|BrushMask|BrushCoordinate|SidecarRepository|Curation|Snapshot|AdvancedMasks|PreviewExportRecipeParity|RawRenderRecipeResolver|DCPProfileFailClosed|AdjustmentClipboard|ReleaseVersion'
swift test --scratch-path "$integration_scratch"
swift build --scratch-path "$integration_scratch" -Xswiftc -strict-concurrency=complete
swift build --scratch-path "$integration_scratch" --configuration release --product LumaHarbor
xcodebuild -project Apps/LumaHarborPad.xcodeproj -scheme LumaHarborPad -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -configuration Debug -derivedDataPath "$integration_ios_sim" CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Apps/LumaHarborPad.xcodeproj -scheme LumaHarborPad -sdk iphoneos -destination 'generic/platform=iOS' -configuration Debug -derivedDataPath "$integration_ios_device" CODE_SIGNING_ALLOWED=NO build
git diff --check
```

每條分別記錄 exit code，不以最後一條成功覆蓋前面失敗。新增 suite 不符合 filter 時加入；記錄實際 executed/skipped/failures，不能把零匹配當成功。

RAW fixture 由已核對的本機環境變數 `LUMAHARBOR_RAW_FIXTURE_DIR` 提供，再執行 `swift test --scratch-path "$integration_scratch" --filter RawFixtureTests`；未設變數先查素材可用性，不把整套跳過列 PASS。不得把 fixture 路徑／名稱／digest 放進可提交報告。

Mac bundle 使用既有 `Scripts/build-app-bundle.sh release`，依腳本契約檢查必要資源與 `Scripts/verify-release-privacy.sh`。另用 `Scripts/package-mac-release.sh release` 在 TARGET 自己的全新 `dist/` 產生未發布的測試 ZIP，驗證解壓內容、checksum 與 privacy gate；不得覆寫已有產物。這些只供本機驗證，不取代日常安裝版、不上傳發行位置。公開發布、版本升級和日常裝置同步留待另行授權；UI-DEVICE 使用獨立測試部署，若安裝會覆蓋使用者現有 App，先確認該操作已獲授權。

### 13.2 效能與像素證據

- 同程序或相同隔離環境交錯 baseline/current，預熱後至少各 8 次，整組重跑 2 輪；記錄素材尺寸、decode size、硬體、recipe、p50/p95、peak memory 及取消延遲。
- 空筆刷場景：每輪 p50 不得比 baseline 慢超過 `max(5 ms, baseline p50 × 5%)`；若超過，先排除 RAW/Core Image 波動再判 FAIL，不靠刪慢樣本過關。`≤150 ms` 仍為既有互動目標，不能把單輪達標當成全部素材保證。
- 有筆刷場景：固定一個和十個 mask、每 mask 十條 100-point path，測 1600px preview 與至少一張可用真實 RAW 原尺寸匯出，列實際時間／記憶體及手勢回應。沒有這些量測不能引用先前「空筆刷無回歸」作為有效負載的效能結論；若出現主執行緒渲染、無法取消、OOM 或 UI 不可操作，列 FAIL。
- 像素比較先通過白色／灰色／非對稱控制影像；same-size unchanged regions 容差與 landmarks 依 §7。WB 指定 D65 Lab／ΔE00 與灰卡 E 指標沿用原規格，不自行放寬。

## 14. 回退與後續發布

- 在 TARGET 可按階段回退本任務程式變更，SOURCE 與 MAIN 不受影響；不得以 destructive reset 清除別人的工作。
- 一旦測試圖庫產生 v5，回退至 v4 App 不代表資料可向下相容。保留原檔及隔離副本，舊 App 應安全拒絕；沒有授權不批次降版、不刪 brushMasks、不回寫舊快照。
- WB 最後合法值防線及 MAIN Native fail-closed 不得在局部回退時單獨移除，除非整體回到已驗證且等價的保護版本。
- 發布前再次確認 origin/main 是否前進，重新評估差異與受影響 gates；不自動 merge/rebase。
- 產品發布仍需獨立授權、同步 semantic version／internal build、全新公開檔名、privacy scan 與 MAIN 同 SHA 的 Mac／可用 iPad 部署。此次文件不指定新公開版本，也不覆寫既有 `0.1.0` 產物。

## 15. 實作交付與唯一下一步

後續實作交付應包含：

1. TARGET 的 base／HEAD、來源 manifest 與逐項採用／適配／排除清單；公開版只含相對路徑和非敏感證據。
2. 與本規格對應的產品／測試差異，尤其 Sidecar v5、curation 權威、snapshot 清空、新舊筆刷和 recipe 不退化的證據。
3. `docs/testing/reports/2026-10-05-mainline-white-balance-brush-integration.md`：§12 全矩陣、原 WB／brush 子矩陣、命令／exit／counts、UI／真機／素材限制、效能及像素結果。
4. TARGET `docs/coordination/CURRENT.md` 的最新狀態與主線基準；`DECISIONS.md` 記錄 v5／兩種筆刷共存，不覆寫既有 D-006。
5. 依 `HANDOFF_TEMPLATE.md` 留下可重現的交接；測試產物與私人素材保留本機，不依賴聊天或已消失的暫存 probe。

**唯一下一步：**以本 spec 展開實作計畫，先完成 P0 的 MAIN/SOURCE 差異與來源保全清單，再進入 P1。開始產品寫入前，確認 TARGET 和單一 writer；此文件本身不代表任何驗收已通過。

## 16. 本次文件檢查

- [x] 核對本機與遠端 main／來源 HEAD，區分 committed／dirty／untracked。
- [x] 核對主線 v4、既有筆刷、recipe、curation 與 snapshot 保存接點。
- [x] 明訂行為移植策略、v5、舊檔／舊 App 保護及兩種筆刷共存。
- [x] 定義分階段交付、完整驗收與回退，不沿用歷史 PASS。
- [ ] TARGET 實作與驗收：本輪未執行。
