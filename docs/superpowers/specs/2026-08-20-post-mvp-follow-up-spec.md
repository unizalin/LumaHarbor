# LumaHarbor MVP 合併後修正與後續工作規格

日期：2026-08-20

基準版本：`46794bb`

工作分支：`codex/post-merge-review-fixes`（**狀態更新 2026-08-21**：本文件記錄的修正已陸續直接進到 `main` 並推送到 `origin/main`，這個分支本身已無未合併的獨有變更，僅保留作為歷史記錄）

## 目的

本文件記錄 MVP 合併後修正包的完成狀態、合併前仍需完成的驗收，以及不阻擋本次修正的技術債與下一階段功能。各類工作不得混為同一個「尚未完成」清單，以免長期項目阻塞必要修正。

## 本次修正包已完成

- 七組巢狀調整模型在直接修改屬性時會立即套用合法範圍限制。
- `AdvancedToneCurve` 會清理非有限值，並把控制點的 `x`、`y` 限制在 `0...1`。
- HSL 對無彩色與近無彩色像素採用中性處理，不再把灰階誤判為紅色色相。
- Tone Curve LUT 在 `resolution == 1` 時有明確且有限值的輸出行為。
- 新增上述邊界條件的單元測試。
- 更新手動驗證紀錄，不再把尚未覆蓋的 HSL 色帶標記為完成。
- `swift build -Xswiftc -strict-concurrency=complete` 已通過。
- Claude 複核後沒有 Critical 或 Important 等級的程式阻擋項。

## Gate A：本次修正合併前必須完成

> **狀態（2026-08-20）：A1、A2 均已完成，Gate A 達成可合併狀態。** 證據：
> `swift test -Xswiftc -strict-concurrency=complete`（421 測試）＋
> `LUMAHARBOR_RAW_FIXTURE_DIR=... swift test --filter RawFixtureTests`（9 測試）
> 全綠，記錄於 `docs/superpowers/specs/2026-08-19-adjustment-engine-expansion-design.md`
> 進度日誌第四則（A1）；HSL 八色帶（含本次補上的黃／綠／青／紫／洋紅）人工視覺
> 驗證記錄於 `docs/testing/2026-08-19-adjustment-engine-manual-verification.md`
> 「Follow-up: yellow/green/aqua/purple/magenta」章節（A2）。以下內容保留作為
> 驗收要求的原始記錄。

### A1. 完整 XCTest

目前環境只有 x86 Command Line Tools，因缺少可用的 `XCTest` 模組，無法在本機完成完整測試。需在 Apple Silicon 且已選用完整 Xcode 的環境執行：

```bash
swift test -Xswiftc -strict-concurrency=complete
```

若有合法的私有 RAW fixture，另執行：

```bash
LUMAHARBOR_RAW_FIXTURE_DIR=/absolute/path/to/fixtures \
  swift test --filter RawFixtureTests
```

至少確認下列新增案例通過：

- 巢狀調整參數直接 mutation 後仍會 clamp。
- HSL 紅色色帶調整不會改變中性灰。
- Tone Curve LUT 在 resolution 1 時輸出有限值。

### A2. HSL 八色帶人工驗證

現有人工測試只明確涵蓋紅、橙、藍。需用色彩豐富且可重現的測試圖完成以下五個色帶：

- 黃（Yellow）
- 綠（Green）
- 青（Aqua）
- 紫（Purple）
- 洋紅（Magenta）

每個色帶至少驗證 Hue、Saturation、Luminance 的可見效果與相鄰色帶過渡，並確認調整紅色色帶時中性灰不偏色。結果更新至 `docs/testing/2026-08-19-adjustment-engine-manual-verification.md`。

### A3. 驗收規則

- A1 與 A2 都完成後，才標記本修正包為可合併。
- 若產品負責人決定接受未完成的人工色帶覆蓋，必須在驗證文件中明確記錄接受者、日期、缺口與風險，不得直接勾選為已通過。
- 私有 ARW、使用者照片及其他受限制 fixture 不得加入 Git。

## Gate B：調整引擎技術債（不阻擋本次修正）

### B1. Core Image Kernel 遷移

> **狀態（2026-08-20）：已完成。** `advancedToneCurve` 與 `hslAdjust`（repo 內實際唯二使用已棄用 `CIKernel(source:)`/`CIColorKernel(source:)` 的 kernel；Split Toning 全程用標準 `CIFilter`，無需遷移）已改為 Metal-based `CIKernel`，原始碼在 `Sources/RawProcessingCore/Kernels/AdjustmentKernels.metal`，由新增的 SwiftPM build plugin `Plugins/CompileMetalKernels` 於建置時編譯進 `default.metallib`。像素等價驗證（maxDiff=0.0，涵蓋兩個 kernel 共 251 組測試像素/參數組合）與完整 `swift test`（421+9 全綠）紀錄於 `docs/superpowers/specs/2026-08-19-adjustment-engine-expansion-design.md` 進度日誌第五則。以下內容保留作為原始要求記錄。

目前 HSL 與 Split Toning 仍使用已棄用的 CIKL source initializer。後續應遷移至 Metal kernel，並用像素輸出測試確認結果等價；本次只抑制 immutable kernel 造成的 Swift 6 Sendable 誤報，不改演算法。

### B2. XMP／Preset 語意定義

在實作 Lightroom XMP 或 preset 匯入匯出前，必須先定義並測試：

- `Sharpening.detail` 與 `Sharpening.masking` 的實際影像語意。
- Luminance Noise Reduction 與 Color Noise Reduction 是否能獨立控制。
- 未支援欄位的保留、忽略與 round-trip 策略。
- LumaHarbor 參數範圍與 Lightroom 參數範圍的映射及版本策略。

### B3. 空間參數一致性

> **狀態（2026-08-20）：Sharpening／Grain 已完成，NoiseReduction 記錄為已知限制不修。** Vignette 本來就用「佔對角線比例」表示，無需處理。`DecodedRawImage.scaleFactor` 與 `AdjustmentPipeline.apply(...scaleFactor:)` 讓 Sharpening 的像素半徑、Grain 的模糊半徑依預覽／匯出的實際解碼縮放比例正規化，匯出（`scaleFactor` 恆為 1）行為不變，只修正預覽的相對強度。Grain 底層雜訊紋理本身的取樣頻率仍與解碼解析度綁定，NoiseReduction 沒有可控制的半徑參數，兩者都記錄為已知限制。細節與測試紀錄見 `docs/superpowers/specs/2026-08-19-adjustment-engine-expansion-design.md` 進度日誌第六則。以下內容保留作為原始要求記錄。

確認 sharpening、noise reduction、grain 等以像素或半徑表示的效果，是否需要依原圖尺寸、縮放比例或輸出尺寸正規化，避免預覽與輸出結果不一致。

## MVP 已接受的 P2 待辦（不阻擋本次修正）

- ~~選單點擊 Undo／Redo 可用，`Cmd+Z`、`Cmd+Shift+Z` 快捷鍵本身仍未在真機上完成人工鍵盤驗證。~~ **已完成（2026-08-21）。**
- 現行 `CIRAWFilter` 環境尚無法穩定觸發 unsupported RAW 的錯誤路徑。
- 唯讀位置儲存失敗目前只顯示 tooltip，需改善可見性與復原指引。
- 三項 Instruments 效能指標尚未取得正式量測結果。
- APFS 與 exFAT 的完整驗證覆蓋仍不對稱。
- 曾出現但尚未重現的 `NSCocoaErrorDomain 4097` 需持續觀察。
- ~~`UndoRedoKeyEquivalentFix.monitor` 仍有 Swift 6 concurrency warning，應獨立修正並加上鍵盤回歸測試。~~ **已完成（2026-08-21）。**

> **狀態（2026-08-21）**：`UndoRedoKeyEquivalentFix.monitor` 的 Swift 6 concurrency warning 已修（整個 enum 標記 `@MainActor`，`swift build -Xswiftc -strict-concurrency=complete` 乾淨無警告）。比對／判斷邏輯已拆成獨立可測的 `UndoRedoKeyEquivalentFix.match(charactersIgnoringModifiers:modifierFlags:)`，新增 `Tests/LumaHarborAppTests/UndoRedoKeyEquivalentFixTests.swift`（7 個案例）。過程中順便修掉一個真的邏輯瑕疵：原本只檢查 `modifierFlags.contains(.command)`，代表 ⌥⌘Z、⌃⌘Z 會被誤判成一般 Undo；改用 `modifierFlags.intersection(.deviceIndependentFlagsMask)` 做**精確**比對（`[.command]` → undo，`[.command, .shift]` → redo，其餘一律不匹配）。全部 433 個獨立測試案例皆有通過證據：不設 `LUMAHARBOR_RAW_FIXTURE_DIR` 執行 `swift test` 為 433 個案例中 424 個執行且通過、9 個（`RawFixtureTests`）跳過、0 failed；另外設定 `LUMAHARBOR_RAW_FIXTURE_DIR` 單獨執行 `RawFixtureTests` 補上那 9 個，9/9 通過（`Executed 433 tests, with 9 tests skipped and 0 failures` 這行 summary 裡的 433 已經包含 9 個 skipped，不是額外的 442——此處先前也誤寫過，已訂正，另見 `docs/testing/reports/2026-08-19-mvp-acceptance.md` §5 的同一次訂正）。
>
> **真機鍵盤驗證（2026-08-21，同日稍後完成）**：用 `Scripts/build-app-bundle.sh debug` 打包成正式 `.app`（未打包的裸執行檔 `NSApplicationActivationPolicy` 是 `.prohibited`，無法成為前景 app，這是先決條件，之前沒打包過所以卡住）。載入本機 fixture `Fixtures/Private/Sony-ARW`（線上磁碟，非離線的 `APFS-Test`），選取 `_DSC1896.ARW`，把「曝光」滑桿拖到 +3.94（明顯過曝、肉眼可辨）。過程中先嘗試用 `CGEvent` 合成鍵盤事件與 AppleScript `System Events keystroke` 兩種方式自動模擬 Cmd+Z／Cmd+Shift+Z，但發現這台機器目前作用中的中文（注音）輸入法會攔截／轉換合成的 key code（同樣手法對 TextEdit 送 A/B/C 的 key code，出來的是注音符號「ㄏ」而非英文字母），代表合成按鍵已被輸入法污染，測出來的結果沒有參考價值，因此放棄自動化模擬，改為請使用者本人在鍵盤上實際按下：
> - `Cmd+Z`：曝光由 +3.94 → 0.00，畫面由過曝變回原圖，**確認有效**。
> - `Cmd+Shift+Z`：曝光由 0.00 → +3.94，**確認有效**。
>
> 每次截圖都用 `screencapture -l<CGWindowID>` 鎖定 LumaHarbor 單一視窗（`CGWindowID` 由一支小型 Swift 腳本經 `CGWindowListCopyWindowInfo` 取得，不是靠螢幕座標框選），過程未拍到使用者其他視窗內容。測試結束已 `kill` 掉打包出來的 app process，確認 `Fixtures/` 底下沒有留下追蹤中的變更（`.lumaharbor`、`.DS_Store` 皆在 `.gitignore` 範圍內），也沒有把任何調整存檔到 fixture 的 sidecar。至此 `Cmd+Z`／`Cmd+Shift+Z` 在真機上確認會正確觸發，不再是「未驗證」項目。

## 下一階段產品功能

以下項目應各自建立獨立 spec、驗收條件與 commit，不併入本次修正包：

1. Preset 與 Lightroom XMP 相容層。
2. Crop、Rotate 與局部調整工具。
3. 批次套用調整與批次匯出。
4. 匯出格式、品質、色彩空間與 metadata 選項。

## 執行與交接規則

- Claude Code 與 Codex 不得同時修改相同檔案；一方實作時，另一方只做 review 或等待交接。
- 每個獨立後續項目使用獨立 commit；不要把 Gate A 驗收紀錄與新功能混在同一個 commit。
- 代理切換或可用 token 接近下限前，更新共用 `HANDOFF.md`，記錄完成項、未完成項、測試結果、分支與 commit。
- 合併前再次執行 `git diff --check`、完整 build、完整 test，並確認沒有加入私有 fixture 或無關檔案。

## 完成定義

本文件中的「本次修正包完成」只代表程式修正與靜態／build 驗證完成；只有 Gate A 的自動測試及人工 HSL 驗證都留下可追蹤結果後，才達到可合併狀態。Gate B、P2 與下一階段產品功能應持續保留在 backlog，但不回頭阻擋已驗收的修正包。

## 交接狀態（2026-08-21，Claude Code session）

- **分支／commit**：工作直接在 `main` 上進行，目前 HEAD 為 `f95d064`（`fix: harden Undo/Redo key-equivalent matching and verify on device`），已 `git push` 到 `origin/main`，working tree 乾淨、無未 commit 變更。
- **本次 session 完成項**：
  - `UndoRedoKeyEquivalentFix` 修掉真的邏輯瑕疵（⌥⌘Z／⌃⌘Z 誤判成一般 Undo）、消除 Swift 6 concurrency warning、拆出可單元測試的 `match(...)`，新增 7 個測試案例（見 P2 待辦區塊內 2026-08-21 狀態說明的完整細節）。
  - `Cmd+Z`／`Cmd+Shift+Z` 已在真機打包的 `.app`（`Scripts/build-app-bundle.sh debug`）上由使用者本人實際按鍵驗證通過，不再是「未驗證」項目。
  - 驗證過程中順帶清掉本機環境的建置產物：scratchpad 內的截圖／測試腳本、`build/LumaHarbor.app`、`.build/`（543MB）皆已用 `trash` 移除；`.build` 清空後重新執行 `swift build`／`swift test -Xswiftc -strict-concurrency=complete` 確認能從零乾淨重建，433 個測試執行、9 個 `RawFixtureTests`（需要 `LUMAHARBOR_RAW_FIXTURE_DIR`）skip、0 failure。
  - 確認 `Fixtures/` 底下沒有殘留任何進 git 追蹤的變更（`.lumaharbor`、`.DS_Store` 皆在 `.gitignore` 範圍內），沒有私有 fixture 被加入版本控制。
- **仍未完成、留在 backlog（不阻擋目前狀態）**：
  - Gate B2（XMP／Preset 語意定義）—— 尚未開始，需要獨立 spec。
  - P2 待辦區塊中除 Undo/Redo 快捷鍵外的其餘五項（unsupported RAW 錯誤路徑、唯讀位置儲存失敗的可見性、Instruments 效能量測、APFS／exFAT 覆蓋不對稱、`NSCocoaErrorDomain 4097` 未重現案例）—— 均未變動，狀態與 2026-08-20 相同。
  - 「下一階段產品功能」四項（Preset/XMP、Crop/Rotate/局部調整、批次處理、匯出選項）—— 均未開始。
- **下一位接手者需要知道的環境細節**：這台機器上有作用中的中文（注音）輸入法，會讓「合成鍵盤事件」（不論是 `CGEvent` 底層 key code 還是 AppleScript `System Events keystroke`）的結果失真——同樣的合成 key code 送到別的 app 會被輸入法轉換成注音符號而非預期的英文字元。因此任何需要驗證真實鍵盤快捷鍵行為的測試，在這台機器上都必須請人親自按鍵，不能單靠程式化模擬下結論。
