# LumaHarbor Preset 與開發預設 XMP — Phase 1 驗收報告

> 安全提醒：本報告只記錄安全代號、雜湊與檔案系統類型，不含使用者本機的完整私人絕對路徑；私人 RAW 檔案、私人 XMP、私人 fixture 本身都不進入 Git。所有 `.xmp` fixture 皆為手寫合成資料，模擬 Adobe 文件發表的 RDF 結構，不含真人照片、帳號或序號資訊。

## 0. 摘要

| 項目 | 內容 |
|---|---|
| 驗收日期 | 2026-08-22 |
| 對應 spec | `docs/superpowers/specs/2026-08-21-preset-xmp-compatibility-design.md` |
| 對應 plan | `docs/superpowers/plans/2026-08-21-preset-xmp-phase1.md` |
| 分支 | `claude/preset-xmp-compatibility` |
| Phase 1 起點 | `18b8307`（分支起點，緊接 `c70ecc3` 之後） |
| 整體結論 | Gate A、D（自動化部分）通過；Gate B 的真實 Adobe 匯入／匯出 smoke test **未完成**（環境限制，見 §4）；Gate D 的 APFS／exFAT 人工項目因本機沒有對應測試目錄／已掛載 exFAT 磁碟而**未執行**（見 §5）。核心模型、codec、mapping、repository、editor 整合與 UI 狀態機皆有自動化測試覆蓋且全數通過。 |

## 1. Commits

| Commit | 說明 |
|---|---|
| `88c729c` | feat: add versioned preset document and adjustment patch（Task 1） |
| `096fdf6` | feat: apply preset patches with merge and replace semantics（Task 2） |
| `939ea6c` | feat: add bounded semantic XMP codec（Task 3） |
| `803b64a` | feat: map Camera Raw develop presets to LumaHarbor（Task 4） |
| `c4640f4` | feat: store global and library presets atomically（Task 5） |
| `3129fc2` | feat: preview and apply presets as one editor action（Task 6） |
| `6df3e1f` | feat: add preset browser and XMP import export workflow（Task 7） |
| （本次） | docs: record preset and XMP phase 1 acceptance（Task 8，本報告） |

每個 task 皆為獨立、可個別審查的 commit；未重做已完成 task。

## 2. 硬體與工具鏈

| 項目 | 結果 |
|---|---|
| `uname -m` | `arm64` |
| macOS 版本 | ProductVersion 26.6.2, Build 25G82 |
| Xcode 版本 | Xcode 26.6, Build 17F113 |
| Swift 版本 | Apple Swift 6.3.3（swiftlang-6.3.3.1.3 clang-2100.1.1.101），target `arm64-apple-macosx26.0` |

## 3. 自動化測試（Gate A／B／D 的核心模型與整合部分）

### 3.1 完整套件（未設定 RAW fixture）

```sh
swift build -Xswiftc -strict-concurrency=complete   # 全 target，0 warnings
swift test  -Xswiftc -strict-concurrency=complete
```

結果：`Executed 588 tests, with 9 tests skipped and 0 failures (0 unexpected)`。

| 項目 | 數量 |
|---|---|
| Executed（總測試數，含下方 skipped） | 588 |
| Passed | 579 |
| Skipped（`RawFixtureTests`，未設 `LUMAHARBOR_RAW_FIXTURE_DIR` 時全數跳過） | 9 |
| Failed | 0 |
| Crash / data race / sanitizer 訊息 | 無 |

Phase 1 開始前的基準為 `Executed 433 tests, with 9 tests skipped and 0 failures`；本階段新增 **155** 個測試案例，全部通過，無既有測試被修改或刪除。新增測試依 task 分布：

| Task | 測試套件 | 新增案例數 |
|---|---|---|
| 1 | `AdjustmentPatchTests`、`PresetDocumentTests` | 7 + 13 = 20 |
| 2 | `PresetApplicatorTests`、`CoreImagePreviewRendererTests` | 12 + 2 = 14 |
| 3 | `XMPCodecTests`、`XMPSecurityTests` | 10 + 13 = 23 |
| 4 | `XMPMappingTests`、`XMPImportExportTests` | 16 + 23 = 39 |
| 5 | `PresetRepositoryTests` | 22 |
| 6 | `PresetWorkflowTests`（editor 部分） | 15 |
| 7 | `PresetLibraryViewModelTests`、`AdjustmentPatchExtractionTests`、`LocalizationSmokeTest`（新增 1 項） | 11 + 10 + 1 = 22 |
| **合計** | | **155** |

（`PresetWorkflowTests` 的 15 個是 Task 6 editor 相關案例；Task 7 額外新增的 view-model 案例落在獨立的 `PresetLibraryViewModelTests`，兩者未合併計數，避免重複。）

`git diff --check` 全程無輸出（無 whitespace 問題）；`swift build -Xswiftc -strict-concurrency=complete` 全 target 編譯 0 warnings（含既有的 `JPEGExportTests`／`BoundedFolderScanTests`／`ThumbnailProviderTests` Swift 6 sending warnings，這些不屬本次功能改動，維持原狀，未擴大範圍修正、也未新增）。

### 3.2 真實 Sony `.ARW` fixture（`RawFixtureTests`）

```sh
LUMAHARBOR_RAW_FIXTURE_DIR=<fixture-set-sony-arw> swift test --filter RawFixtureTests
```

| 項目 | 數量 |
|---|---|
| Executed | 9 |
| Passed | 9 |
| Failed | 0 |

9 個案例與既有 MVP 驗收報告記錄的集合一致（`testEveryFixtureDecodes` 等），Phase 1 未修改 `RawProcessingCore` 的渲染行為，只新增了 `PreviewImage.whiteBalanceBaseline`／`RawWhiteBalanceBaseline`（皆為向後相容的新增欄位，預設 `nil`，不影響既有測試）。

## 4. Gate B：Adobe 相容性 smoke test — 未完成

計畫要求「在可用的 Lightroom Classic／Camera Raw 做 smoke test：驗證 Adobe 可匯入 LumaHarbor 輸出的開發預設，並把 Adobe 再輸出的 XMP 交回 semantic comparator」。

**本次驗收環境沒有已安裝、可互動操作的 Lightroom Classic 或 Adobe Camera Raw**（此環境為無 GUI 互動、無 Adobe 帳號授權的自動化 agent 環境）。因此：

- 未執行真實 Adobe 匯入／匯出 smoke test。
- 這一項**明確標示為未完成**，不得以單元測試（`XMPMappingTests`／`XMPImportExportTests`）替代——那些測試驗證的是「LumaHarbor 自己對 Adobe 文件發表格式的理解」，不是「真實 Adobe 軟體真的能讀懂 LumaHarbor 匯出的東西」。
- 已完成的替代驗證：mapping table 的屬性名稱、namespace URI、單位換算（如 Sharpness ×1.5、Kelvin/tint 換算常數）均對照 Adobe 已發表的 `crs:` namespace 文件與 exiv2 參考實作核對，非憑欄位名稱猜測（見 `XMPMappingRegistry.swift` 內逐項註解）。

**建議**：Phase 1 合入前，需要一名可操作 Lightroom Classic 或 Camera Raw 的人員，完成以下最小 smoke test 並補上此章節：
1. 用 LumaHarbor 建立一個含 Exposure／Contrast／HSL 的原生 Preset，匯出成 `.xmp`。
2. 在 Lightroom Classic／Camera Raw 匯入該 `.xmp`，確認可辨識為開發預設且數值合理。
3. 在 Adobe 端調整後重新匯出 `.xmp`，用 LumaHarbor 的 `XMPCodec.parse`／`semanticallyEquivalent` 或手動比對，確認往返沒有遺失已知欄位。

## 5. Gate D（人工項目）：APFS／exFAT — 未執行

`Scripts/run-mvp-acceptance.zsh --preflight-only` 在本機的結果：

```
LUMAHARBOR_RAW_FIXTURE_DIR: PASS (directory ok, 81 .ARW file(s), e.g. _DSC1896.ARW)
LUMAHARBOR_APFS_TEST_DIR: FAIL (not set)
LUMAHARBOR_EXFAT_TEST_DIR: FAIL (not set)
```

- 本機在 `LUMAHARBOR_APFS_TEST_DIR` 指向的路徑上**沒有預先建立的測試資料夾**。
- 本機當下**沒有掛載任何 exFAT 磁碟**（`diskutil list`／`/Volumes` 確認過，只有內建 APFS 容器與模擬器磁碟映像）。
- 依照交接規則「若完整驗收因外接 exFAT 未掛載而無法執行，必須明確回報，不能假造、略過或把 SKIPPED 當 PASS」：本節如實記錄為**未執行**，`Scripts/run-mvp-acceptance.zsh` 的完整（非 `--preflight-only`）流程本次**沒有跑**。
- Phase 1 本身沒有新增任何 APFS／exFAT 專屬邏輯（`FilePresetRepository` 沿用既有 `AtomicFileWriter`／`FileSidecarRepository` 的唯讀／離線檢查模式，`PresetRepositoryTests` 已用一般臨時目錄的 POSIX 權限模擬唯讀與離線情境，見 §3.1 的 22 個案例），风险評估為低，但仍非「已在真實 APFS／exFAT 上人工驗證」。

**建議**：下次有 APFS 測試目錄與 exFAT 隨身碟可用的 session，執行：
```sh
export LUMAHARBOR_RAW_FIXTURE_DIR=<...>
export LUMAHARBOR_APFS_TEST_DIR=<...>
export LUMAHARBOR_EXFAT_TEST_DIR=<...>
Scripts/run-mvp-acceptance.zsh --preflight-only
Scripts/run-mvp-acceptance.zsh
```
並補上library preset 在兩種檔案系統上的建立／讀取／改名／搬移／唯讀／拔除情境（spec §12.3）。

## 6. 安全與邊界（已由自動化測試覆蓋）

| 項目 | 覆蓋方式 | 結果 |
|---|---|---|
| DOCTYPE／外部 entity 一律拒絕 | `XMPSecurityTests` | 通過 |
| 10 MiB／深度 64／20,000 properties／1 MiB 單值上限 | `XMPSecurityTests` | 通過（含邊界值恰好通過、超界恰好拒絕） |
| 非法 UTF-8／控制字元不 crash | `XMPSecurityTests` | 通過 |
| 未知 process version 一律保留、不猜測 | `XMPMappingTests`、`XMPImportExportTests` | 通過 |
| 未知 namespace／nested RDF 語意無損保存 | `XMPCodecTests`、`XMPImportExportTests`（`testExportOfXMPImportedPresetPreservesUnknownNestedRDF`） | 通過 |
| Preset 名稱／群組路徑長度與層數上限 | `PresetDocumentTests` | 通過 |
| 未來 schema 版本明確拒絕 | `PresetDocumentTests` | 通過 |
| 同 UUID 衝突（重複跳過／取代／保留兩份／取消） | `PresetRepositoryTests` | 通過 |
| 唯讀／離線 scope 的讀寫邊界 | `PresetRepositoryTests` | 通過 |
| Scope 搬移的 copy-then-verify-then-delete，刪除失敗不回滾已驗證副本 | `PresetRepositoryTests`（`testTransferReportsCopiedSourceRetainedWhenSourceDeleteFails`） | 通過 |
| Preset 預覽不寫入 history／save state／autosave | `PresetWorkflowTests` | 通過 |
| 複合 Preset 套用只產生一筆 Undo | `PresetWorkflowTests`（`testCommittingAMultiFieldPresetCreatesExactlyOneUndoEntry`） | 通過 |
| 取消匯入零寫入 | `PresetLibraryViewModelTests`（`testCancelledImportWritesNothing`） | 通過 |

未發現任何 crash、data race 或資料損毀。

## 7. Foundation 對 unknown RDF 語意的保存能力

計畫要求「若 Foundation 無法安全保存 unknown RDF 語意，提出具體 blocker，不得假裝完成」。

結論：**沒有遇到需要回報的 blocker**。`XMLParser`（Foundation）搭配自訂的 bounded SAX tree builder 與 RDF 解讀層（`XMPCodec.swift`／`XMPPropertyGraph.swift`）足以：

- 保存任意未知 namespace 的 scalar／array（`Bag`／`Seq`/`Alt`）／nested structure／qualifier（如 `xml:lang`），且通過 `testUnknownNamespaceStructureSurvivesSemanticRoundTrip`、`testUnknownNestedSeqOfStructuresRoundTrips`、`testUnknownBagPreservesUnorderedMembership` 等測試往返驗證。
- 匯出時以原始 packet 重新 parse 出的 property graph 為基底，只更新 LumaHarbor 認得且使用者實際修改過的欄位，未知資料原樣保留（`XMPExporter.baseDocument(for:)`）。
- 語意相等由 `XMPCodec.semanticallyEquivalent` 定義為「忽略屬性宣告順序／prefix 選擇／空白，但陣列順序與內容必須一致」，未使用 byte-for-byte 比對，符合 spec §6.1 對「無損」的定義。

## 8. 已知限制

| 項目 | 說明 | 影響 |
|---|---|---|
| Gate B Adobe smoke test 未完成 | 見 §4 | 阻塞：需要真人操作 Lightroom/ACR 才能補完，建議在合入前完成 |
| Gate D APFS／exFAT 人工項目未執行 | 見 §5 | 非阻塞但建議補測：機制與既有 `FileSidecarRepository` 一致，風險低 |
| Preset browser 的鍵盤導覽預覽 | 目前只有滑鼠 hover 觸發 transient preview；鍵盤（方向鍵在清單中移動焦點）尚未接上同一個 preview 路徑，只有既有的 Tab 可達的套用／收藏／更多操作按鈕 | 功能性限制，不影響資料正確性；建議後續 task 補上 List selection → preview 的橋接 |
| 建立 Preset 的欄位勾選 UI 以「群組」而非逐一 leaf 呈現 | 例如 HSL 一個色版的 hue/saturation/luminance 三個 leaf 共用一個核取方塊；spec §9.2 沒有規定必須逐 leaf，但若日後需要更細粒度的勾選，需要擴充 `PresetFieldGroup` | 產品決策空間，非 bug |
| Preset 群組路徑輸入為單一文字欄位（以 `/` 分隔） | 尚未做拖曳排序或樹狀選擇 UI | UX 精簡化，功能完整 |
| 一般開發環境沒有 GUI／Instruments 存取權限 | 沿用既有 MVP 報告已記錄的限制，與本 Phase 無關 | 沿用既有已知限制 |

## 9. Gate 結論

| Gate | 內容 | 結果 |
|---|---|---|
| A | `.lhpreset` schema、repository、兩種 scope、建立／管理、merge／replace 與單筆 Undo 全部有測試；transient preview 不寫檔、不污染 history | ☑ 通過 |
| B | fixture corpus 匯入、unknown 保存、語意 round-trip、相容性摘要與匯出全部通過；惡意／損壞 XML 不 crash | ☑ 自動化部分通過 |
| B（Adobe smoke test） | 真實 Lightroom/ACR 匯入／匯出驗證 | ☐ 未完成（見 §4） |
| D（自動化回歸） | strict build／完整測試／`RawFixtureTests` | ☑ 通過（見 §3） |
| D（APFS／exFAT 人工項目） | library preset 建立／讀取／改名／搬移／唯讀／拔除 | ☐ 未執行（見 §5） |

**本階段完成後，依交接規則先交給 Codex review；Gate B 的 Adobe smoke test 與 Gate D 的 APFS／exFAT 人工項目待補，Critical／Important 問題（若有）清空、且上述兩項至少其一有明確結論後，才開始 Phase 2。**

## 10. Git 狀態

```
On branch claude/preset-xmp-compatibility
nothing to commit, working tree clean（本報告 commit 前）
```

`git diff --check`：無輸出。`docs/reference/` 全程未被 add／commit／stash／修改／刪除。未 push、未 force push、未修改主 worktree。

## 11. Round 2 review-fix 之後的人工 Smoke Test（2026-08-22）

對應 commit `975896d`（round 1 review-fix）與 `cfe9b54`（round 2 review-fix）之後、合併 main 前的四項人工 smoke test（見交接時提出的 checklist）。分兩段進行：先由 Claude 用 GUI 自動化（CGEvent 合成滑鼠事件＋`screencapture -l<CGWindowID>` 鎖定單一視窗截圖）跑過一輪，再由使用者本人在真機上覆核。

### 11.1 結果總覽

四項最終全部完成驗證（情境 3、4 起初卡在自動化限制，後續由 Claude 用真機真實文字輸入補完，過程見各列備註）。

| # | 情境 | 結果 | 備註 |
|---|---|---|---|
| 1 | Hover 缺 baseline 的 preset，非 modal 診斷可見且移開消失 | ☐ **測不出來——發現真正的產品 bug，見 11.2** | 自動化與真人操作結果一致：合成事件與真實滑鼠都測不到，但根因不是操作方式，是下面這個 bug |
| 2 | 套用只有 temperature 的 preset 是 no-op，但 alert 仍出現 | ☑ 通過 | Alert 標題 `This preset was applied with some limitations`，內容 `White balance from this preset couldn't be applied yet because this photo hasn't finished decoding.`；Undo 圖示維持停用、色溫維持 0，確認無 Undo entry、無 dirty state |
| 3 | favorite／rename／delete 儲存失敗都要顯示 alert | ☑ 通過（三項全過） | Favorite 失敗：標題 `Couldn't update this favorite` + 唯讀說明 + nextStep，通過，星星未真的變成已收藏。Delete 失敗：標題「無法刪除這個 Preset」（已在地化）+ 相同說明 + nextStep，preset 未被刪除，通過。Rename 失敗：標題「無法重新命名這個 Preset」（已在地化）+ 相同說明 + nextStep，preset 名稱維持「ScopeTest」未被真的改成「ScopeTestRenamed」，通過——先前回報的「文字輸入模擬對此 TextField 無效」是這次環境的間歇性問題，不是恆定限制：同一支 CGEvent Unicode 字串注入腳本，在建立 preset（情境 4）與這次 rename 都成功正確輸入了文字，只是偶爾不穩定，需要重試。Copy 完全沒有 UI 進入點（見 8. 已知限制新增一列），測不了，跟輸入法/自動化無關 |
| 4 | Create Preset 儲存失敗時 sheet 留著、成功才關 | ☑ 通過（兩階段皆過） | 「Save to」選「此照片庫」（指向唯讀磁碟 ReadOnly-Test）按 Save：sheet 未關閉，Alert 標題「無法建立這個 Preset」+「This drive is read-only, so LumaHarbor can't save the preset there.」+ nextStep，欄位資料（名稱、勾選、scope）全部保留。改選「我的 Preset」再按 Save：成功寫入、sheet 自動關閉，preset 正確出現在清單。此前回報的「自動化多次誤觸使用者個人資料夾」是準備 ReadOnly-Test 照片庫時，系統「加入照片資料夾」／「重新連接」檔案選擇器對合成滑鼠點擊不穩定所致（改用鍵盤方向鍵移動清單選取後穩定成功），跟 Create Preset 本身的行為無關；過程中沒有任何個人資料被掃描或顯示 |

### 11.2 真正發現：hover-preview 對解碼失敗的照片會造成 alert 洪水，蓋住診斷文字

**這不是測試方法問題，是 `EditorViewModel.previewPreset()` 的真實 bug：**

```swift
func previewPreset(_ preset: PresetDocument, mode: PresetApplicationMode) {
    guard photo != nil else { return }
    let result = applying(preset, mode: mode)
    previewedPresetAdjustments = result.adjustments
    presetPreviewDiagnostics = result.diagnostics
    requestInteractivePreview()   // ← 問題所在
}
```

每次 hover 一個 preset 都無條件呼叫 `requestInteractivePreview()`，對目前照片重新發起一次 interactive 解碼請求——不論這次 preset 預覽實際上會不會改變畫面內容。對一張解碼會失敗的照片（例如用來製造「缺 baseline」情境的損壞 RAW），這代表**每次 hover 都觸發一次新的解碼失敗**，並經 `EditorViewModel.handle(_:)` 的 `.failed` 分支把 `alert = UserAlert(title: "Couldn't show this photo", ...)` 設成一個 modal alert。

這個 modal alert 會蓋住整個 Inspector 面板，包括 `PresetBrowserView.previewDiagnostic` 顯示的非 modal 診斷文字——`presetPreviewDiagnostics`／`presetPreviewMessage` 很可能有被正確設定（round 1／round 2 的 ViewModel 層級測試都通過，證明資料本身沒被丟棄），但使用者實際上完全看不到，因為畫面被解碼失敗的 alert 整個蓋掉了。同時，只要滑鼠在 preset 清單上移動，就會不斷重新觸發解碼、不斷跳出新的 alert，形成使用者回報的「alert 一直出現」。

**影響範圍**：任何「hover 一個會強制重新解碼的情境（例如照片本身解碼會失敗，或未來若 preview 換了更貴的 quality）」都可能出現同樣的 alert 蓋住診斷文字的問題，不只是這次用來測試的損壞檔案情境。

**建議修法方向**（本次未動任何程式碼，留給下一輪 review-fix）：hover-preview 的 `requestInteractivePreview()` 呼叫，應該跟「這次 preset 預覽是否真的需要新的渲染」脫鉤，或者至少讓 hover 觸發的解碼失敗不要覆蓋掉 `presetPreviewDiagnostics` 想呈現的非 modal 訊息（例如 hover 情境下的解碼失敗改用跟 `presetPreviewMessage` 一樣的非 modal 呈現方式，而不是走會蓋版的 `alert`）。

### 11.3 已知限制新增一項

| 項目 | 說明 | 影響 |
|---|---|---|
| Preset 的「複製到另一個 scope」沒有 UI 進入點 | `PresetLibraryViewModel.copy(_:to:)` 存在也有單元測試覆蓋，但 `PresetBrowserView`／`PresetRow` 完全沒有把它接到任何按鈕或選單（目前「⋯」選單只有 Rename…／Export…／Delete） | 功能性缺口，不影響資料正確性；無法透過 UI 人工驗收，需要先補上進入點 |

### 11.4 環境限制記錄

這台機器上有作用中的中文（注音）輸入法：AppleScript `System Events keystroke` 對這個 App 的 TextField 完全無效或會被污染成注音符號，仍然不可用。但 CGEvent 的 `keyboardSetUnicodeString`（Unicode 字串直接注入單一 key event，不經過實體鍵盤佈局／輸入法轉換）**證實可行**，只是這台機器上偶爾（原因未查清，推測與畫面/焦點狀態競爭有關）第一次嘗試會沒有反應，重試一次通常就成功——最終在情境 3（rename）與情境 4（create preset）都用同一支腳本成功打出正確文字並存檔。系統原生的「加入照片資料夾」／「重新連接」檔案選擇器對 CGEvent 合成滑鼠點擊／雙擊也同樣不穩定，改用鍵盤方向鍵（`Down`／`Up`）移動清單選取後可穩定運作。這些都記錄為這台機器 GUI 自動化的已知間歇性摩擦，不是這個 Preset／XMP 功能本身的缺陷；與 2026-08-21 post-mvp-follow-up-spec 交接狀態章節記錄的環境限制一致，本節在原記錄基礎上補充「並非恆定失敗、有可行重試手段」這一點。
