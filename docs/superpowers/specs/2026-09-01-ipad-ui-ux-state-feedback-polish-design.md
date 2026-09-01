# iPad UI/UX State Feedback Polish 設計規格

日期：2026-09-01

狀態：設計已由使用者口頭核准，等待 spec review 後進入 implementation plan

目標分支：`codex/ipad-ui-ux-state-feedback-polish`

基準：`main` at `f38f3ad7968b2d5faaffa96dda17f308a982846d`

## 1. 背景

iPad 多來源 RAW 圖庫、APFS/exFAT/Files provider、Sony `.ARW` 瀏覽、非破壞式調整值保存、重新授權、移除來源安全性與獨立 pre-landing review 已經完成並 landed 到 `main`。下一階段不是新增更深的 RAW 演算法，而是把使用者實測中反覆遇到的「點了像沒反應」「不知道是在等待還是失敗」「權限/離線/唯讀文字不夠明確」收斂成一致的 iPad 使用體驗。

本規格接續既有 `docs/superpowers/specs/2026-08-30-ipad-ui-ux-state-contract.md`，把其中尚缺項目切成一個可實作、可測試、可交接的小包。

## 2. 目標

這一輪要讓 iPad 版在下列情境中清楚告訴使用者 App 正在做什麼、結果是什麼、資料是否安全：

1. 加入來源與掃描來源。
2. 重新連接或重新授權來源。
3. 移除來源。
4. 開啟 RAW 與保存調整值。
5. 空狀態、離線狀態、需要授權狀態、沒有支援照片狀態。

成功標準是：使用者不需要猜「我點了有沒有反應」，也不會誤以為 LumaHarbor 會搬移、覆蓋或刪除外接磁碟上的 RAW 原檔。

## 3. 非目標

本輪不做：

- 新 RAW 調整演算法。
- Before/After 比較。
- Reset 單項或全部調整。
- 複製/貼上調整值。
- 批次套用。
- JPEG/HEIF 匯出。
- App Store/TestFlight 發佈流程。
- 改寫 Mac 版 UI。

這些都可以是下一階段功能，但不混進本輪，以免 UI 狀態整理失焦。

## 4. 使用者可見狀態模型

### 4.1 來源作業狀態

來源作業必須區分：

- `Adding source…`：使用者剛選取資料夾，App 正在建立來源、保存 bookmark、建立/讀取 manifest。
- `Scanning source…`：來源已建立或已存在，App 正在掃描支援的照片。
- `Reconnecting source…`：使用者正在重新授權或重新連接既有來源，App 正在驗證這是否是同一個來源。
- `Removing source…`：使用者確認移除後，App 正在從本機來源清單和索引移除這個來源。
- `Loading more photos…`：使用者捲動到下一頁，App 正在載入更多照片。
- `Preparing photo…`：使用者點縮圖，App 正在解析照片來源與建立 editor 狀態。
- `Decoding RAW…`：editor 已進入照片開啟流程，但 RAW preview 尚未完成。

任何等待狀態都不能只有 spinner；必須有文字。

### 4.2 來源連線狀態

來源列與相關錯誤必須清楚區分：

- `Ready`：來源可讀，照片可打開。
- `Read-only`：照片可讀，但寫入 sidecar 或保存調整值可能受限。
- `Offline`：外接碟、Files provider 或來源資料夾目前不可用。
- `Needs Access`：security-scoped bookmark 或 Files provider 授權需要使用者重新選取資料夾。
- `Scanning`：來源正在掃描。
- `Partial issue`：掃描部分失敗，但已成功的索引仍可用，且不能因 partial failure 刪除未掃到的照片。

`Read-only`、`Offline`、`Needs Access` 不得共用同一段泛用錯誤文字。

## 5. 功能細節

### 5.1 加入來源與掃描來源

當使用者按 `+` 選資料夾後：

1. 選器關閉後立即顯示 `Adding source…`。
2. 若來源建立成功並開始掃描，文字改為 `Scanning source…`。
3. 若掃描有進度資訊，顯示目前批次或照片數；若沒有精確進度，至少顯示 spinner 與文字。
4. 掃描成功後來源出現在 sidebar，照片逐批出現在 grid。
5. 失敗時顯示可理解原因與下一步，不顯示私人絕對路徑。

安全文案：

> LumaHarbor 只會讀取這個資料夾中的 RAW，不會搬移、覆蓋或刪除原檔。

### 5.2 重新連接與重新授權

當來源是 `Offline` 或 `Needs Access`：

1. 來源列要有明確狀態文字。
2. 使用者點來源或照片時，若不能打開，提示重新授權/重新連接，而不是只顯示「無法開啟」。
3. 使用者開始重新連接後顯示 `Reconnecting source…`。
4. 成功後原來源恢復，不建立重複來源。
5. 若選錯資料夾，要說明身份不符，要求重新選擇原本來源。
6. 若 Files provider 尚未同步或外接硬碟未接上，要提示使用者先確認來源可用。

安全文案：

> LumaHarbor 會確認這是同一個來源，不會只靠名稱或路徑誤接。

### 5.3 移除來源

移除來源必須有確認視窗。確認文字：

> 這只會從 LumaHarbor 移除來源，不會刪除外接硬碟、Files 或資料夾中的 RAW、sidecar 或 manifest。

按鈕：

- `Remove Source`
- `Cancel`

使用者確認後顯示 `Removing source…`。移除成功後來源從列表消失；移除失敗時不得宣稱成功，必須保留可理解錯誤。

### 5.4 開啟 RAW 與保存狀態

開啟照片：

1. 點縮圖後立即顯示 `Preparing photo…`。
2. 若 RAW 解碼仍在進行，editor 顯示 `Decoding RAW…`。
3. 離線、需要授權、不可解碼、唯讀保存受限要顯示不同訊息。
4. 文案不得暗示打開 RAW 會修改原檔。

保存狀態：

- `Saved`：目前調整值已保存，或照片剛打開且沒有未保存變更。
- `Unsaved`：使用者調整了值，尚未完成保存。
- `Saving…`：正在寫入 app metadata 或 sidecar。
- `Save failed`：保存失敗，原 RAW 仍未修改，使用者可重試或重新授權。

若來源唯讀但仍可開啟 RAW，UI 要明確說明「可以查看/調整預覽，但可能無法保存到外部 sidecar」。

### 5.5 空狀態與錯誤狀態

Grid 或主內容區不得空白無說明。至少需要：

- 沒有來源：提示「加入資料夾開始瀏覽 RAW」。
- 來源沒有支援照片：提示「此來源沒有找到支援的 RAW 檔」。
- 來源離線：提示「請接回外接硬碟或確認 Files 來源可用」。
- 需要授權：提示「請重新授權來源資料夾」。
- 搜尋無結果：提示「沒有符合搜尋的照片」。
- 載入失敗：保留既有結果並提供可重試說明。

## 6. 架構

本輪以既有邊界為主，不新增大型 framework。

主要落點：

- `Sources/EditorCore/LibraryBrowserSession.swift`
  - 作為 UI 狀態的主要來源。
  - 必須暴露足夠明確的 operation state，讓 SwiftUI 不必猜測文字。
- `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadLibraryView.swift`
  - 主畫面 overlay、空狀態與 grid 狀態呈現。
- `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadLibrarySidebar.swift`
  - 來源列狀態、離線/授權/掃描提示。
- `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadLibraryProgressOverlay.swift`
  - 等待狀態共用呈現元件。
- `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorView.swift`
  - 保存狀態與 RAW decode/opening 狀態文案。
- `Sources/Localization/Resources/*/Localizable.strings`
  - 所有使用者文案走 localization，不硬寫散落文字。

若既有 model 已有足夠狀態，優先命名與映射；不要為了文案引入重複狀態來源。

## 7. 錯誤處理與隱私

錯誤訊息必須符合：

1. 說明使用者能做什麼。
2. 說明 RAW 原檔沒有被修改。
3. 不顯示私人絕對路徑、完整 mount path、Apple Development Team ID、provider 內部錯誤細節。
4. 不把 `SKIPPED` 或 `NOT RUN` 寫成 `PASS`。
5. 不因為掃描 partial failure 而 prune 未掃描到的既有照片。

## 8. 測試策略

實作時採 TDD。預期新增或更新測試：

- `LibraryBrowserSessionTests`
  - adding/scanning/reconnecting/removing operation state 的轉換。
  - 搜尋/排序/scope 慢查詢時不混入舊 cursor。
  - partial failure summary 不清掉既有成功結果。
- `PadLibraryCompositionContractTests` 或 `PadLibraryAccessibilityContractTests`
  - overlay 必須有可見文字，不只是 spinner。
  - `Offline`、`Needs Access`、`Read-only` 文案不同。
  - 移除來源確認視窗包含 RAW 不刪除文案。
- `PhotoDocumentEditorLibraryOpenTests`
  - 打開外部 RAW 的保存狀態仍是 `Saved`，調整後 `Unsaved/Saving…/Saved` 順序可被觀察。
  - 保存失敗時使用 `Save failed`，且不暗示 RAW 原檔被修改。
- Localization contract test
  - English 與 Traditional Chinese 字串 key 都存在。

驗證命令：

```bash
swift test --filter LibraryBrowserSessionTests
swift test --filter PadLibraryCompositionContractTests
swift test --filter PadLibraryAccessibilityContractTests
swift test --filter PhotoDocumentEditorLibraryOpenTests
swift test
git diff --check
```

若實機/iPad simulator 可用，補跑：

```bash
xcodebuild -project Apps/LumaHarborPad.xcodeproj -scheme LumaHarborPad -destination 'generic/platform=iOS' build
```

## 9. 人工驗測

實作完成後在真實 iPad 上做：

1. 加入 APFS 來源：看見 `Adding source…` → `Scanning source…` → 照片出現。
2. 加入 exFAT 來源：照片與縮圖出現。
3. 拔掉 exFAT：來源列顯示 `Offline`，照片開啟提示要接回。
4. 接回並重新連接：顯示 `Reconnecting source…`，成功後不產生重複來源。
5. Files provider 重新授權：顯示 `Needs Access`，授權後可打開照片。
6. 移除來源：確認視窗明確說不刪 RAW/sidecar/manifest。
7. 開啟 Sony `.ARW`：有 `Preparing photo…` 或 `Decoding RAW…`，進 editor 後有 `Saved`。
8. 調整 Exposure：看見 `Unsaved` 或 `Saving…`，最後回到 `Saved`。
9. 重新打開同一張與重開 App：調整值保留，RAW 原檔 checksum 不變。

## 10. 驗收條件

本輪完成需要：

- 所有新增/更新測試通過。
- 完整 `swift test` 通過。
- `git diff --check` 通過。
- iPad generic build 通過，或明確記為 `NOT RUN` 並說明原因。
- 真機 gate 若未跑，不得宣稱實機完成。
- 文件或 UI 不含私人絕對路徑、mount path、Team ID。
- 移除、重新連接、保存失敗等文案都明確聲明 RAW 原檔沒有被修改。

## 11. 分工建議

若要讓 Claude 參與，建議分工如下：

- Codex：先完成 spec、implementation plan、第一輪 TDD 實作。
- Claude：做獨立 review，專看 UI 狀態是否符合本 spec、是否有漏測、是否誤導 RAW 安全性。

同一時間不可讓兩個 agent 修改同一個 worktree；Claude 若審查，應使用獨立 worktree 或唯讀模式。
