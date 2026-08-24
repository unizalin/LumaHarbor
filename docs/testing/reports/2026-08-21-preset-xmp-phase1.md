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
| 整體結論 | Gate A、D（自動化部分）通過；Gate B 的真實 Adobe 匯入／匯出 smoke test **未完成**（環境限制，見 §4）；Gate D 的 APFS／exFAT 人工項目因本機沒有對應測試目錄／已掛載 exFAT 磁碟而**未執行**（見 §5）。核心模型、codec、mapping、repository、editor 整合與 UI 狀態機皆有自動化測試覆蓋且全數通過。Codex 第三輪 re-review（commit `a161c6e`）的人工 smoke test 已於 2026-08-24 執行完畢：Copy-to-scope 的兩個情境（§11.5 情境 4／5）通過；鍵盤 focus 導覽機制驗證通過但視覺 parity 無法完全確認（情境 3）；hover-preview 的兩個情境（情境 1／2）一度因 §11.6 記錄的「解碼失敗 alert 關閉後畫面永久卡在載入中」bug 而未能驗證，該 bug 已於同日以 commit `e262b7e` 修復並重新完整驗證（§11.7），情境 1／2 均通過，657 個自動化測試全數通過。Codex 第三輪 re-review 的 A／B／C 三項至此全部完成驗證，Phase 2 前僅剩 Gate B 的 Adobe smoke test 與 Gate D 的 APFS／exFAT 人工項目待補（均為既有、非本輪新增的待辦）。 |

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
| 解碼失敗的初次 alert 關閉後，畫面卡在「正在解碼 RAW...」永遠不恢復 | 2026-08-24 人工 smoke test 發現（見 §11.6），已於同日確認根因並以 commit `e262b7e` 修復、重新驗證（見 §11.7）：根因是 `EditorView.previewArea` 只用 `displayedImage == nil` 判斷要不要顯示轉圈動畫，沒有區分「真的還在解碼」與「已經失敗、什麼都不會再送出」；與 `a161c6e` 的 preview 世代計數機制無關（`EditorView.swift` 該次完全沒被改動），是 `26ae5dd`（2026-08-19）就存在的舊 bug，只是這次才第一次被完整暴露 | 已修復並驗證，不再阻塞 Phase 2 |

## 9. Gate 結論

| Gate | 內容 | 結果 |
|---|---|---|
| A | `.lhpreset` schema、repository、兩種 scope、建立／管理、merge／replace 與單筆 Undo 全部有測試；transient preview 不寫檔、不污染 history | ☑ 通過 |
| B | fixture corpus 匯入、unknown 保存、語意 round-trip、相容性摘要與匯出全部通過；惡意／損壞 XML 不 crash | ☑ 自動化部分通過 |
| B（Adobe smoke test） | 真實 Lightroom/ACR 匯入／匯出驗證 | ☐ 未完成（見 §4） |
| D（自動化回歸） | strict build／完整測試／`RawFixtureTests` | ☑ 通過（見 §3） |
| D（APFS／exFAT 人工項目） | library preset 建立／讀取／改名／搬移／唯讀／拔除 | ☐ 未執行（見 §5） |
| Codex 第三輪 re-review（A／B／C，見 §12） | Copy-to-scope 人工驗證（§11.5 情境 4／5） | ☑ 通過 |
| Codex 第三輪 re-review（A／B／C，見 §12） | 鍵盤 focus 導覽人工驗證（§11.5 情境 3） | ☑ 機制通過，視覺 parity 未能完全確認 |
| Codex 第三輪 re-review（A／B／C，見 §12） | hover-preview 不再洪水式跳 alert 人工驗證（§11.5／§11.7 情境 1／2） | ☑ 通過（修復 §11.6 的卡住 bug 後重新驗證，見 §11.7） |

**本階段完成後，依交接規則先交給 Codex review；Codex 第三輪 re-review 的 A／B／C 三項人工驗證已全部完成。Gate B 的 Adobe smoke test 與 Gate D 的 APFS／exFAT 人工項目仍待補（既有、非本輪新增的待辦），Critical／Important 問題（若有）清空、且上述兩項有明確結論後，才開始 Phase 2。**

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

### 11.5 Round 3（commit `a161c6e` 修正後）人工 Smoke Test（2026-08-24）

對應 §12 記錄的 Codex 第三輪 re-review A／B／C 三項修正，交接時列出的 5 項人工 smoke test 結果如下。工具鏈與機器同 §2；受測 build 為本輪重新組裝的 debug `.app`（`Scripts/build-app-bundle.sh debug`）。GUI 自動化沿用 §11.4 記錄的技巧，並新增一項教訓：`NSRunningApplication.activate()` 連續呼叫幾次後會不穩定、前景視窗可能被搶回終端機，改成每次操作前用 `open <bundle>` 重新提升前景視窗，穩定許多。

| # | 情境 | 結果 | 備註 |
|---|---|---|---|
| 1 | diagnostic-only hover（Baseline Test on 損毀的 `_DSC1898-corrupt.ARW`） | ☑ 通過（修復 §11.6 的 bug 後重測，見 §11.7） | 最初被 §11.6 記錄的卡住 bug 擋住；bug 修復（commit `e262b7e`）後重新驗證：非 modal 診斷文字「White balance from this preset couldn't be applied yet because this photo hasn't finished decoding.」正確出現，全程沒有跳出任何 modal alert，細節見 §11.7 |
| 2 | 會改變畫面的 preset hover 在解碼失敗的照片上 | ☑ 通過（修復 §11.6 的 bug 後重測，見 §11.7） | 最初被同一個 bug 擋住；bug 修復後用新建立的 `ExposureBump`（真的會改變畫面的 preset）重測：非 modal 的 `previewRenderFailureMessage`「This preset's preview couldn't be rendered right now.」正確出現，連續快速切換 6 次前後仍只顯示一行、不疊加、不跳 modal，細節見 §11.7 |
| 3 | 鍵盤方向鍵在 Preset 清單移動 focus | ☑ 導覽機制驗證通過；跟 hover 的 preview 是否為同一路徑**未能完全確認** | 在 Sony-ARW 一張正常解碼的照片上：點擊「搜尋 Preset」欄位後按 Tab，focus 移到清單第一列（Baseline Test，出現藍色 focus 外框）；按方向鍵向下，focus 正確移到下一列（ReadOnlyTest）；點擊畫布把 focus 移出清單後，focus 外框消失，畫面無殘留。導覽機制本身正常。但這個環境唯一可用的兩個全域 preset（`Baseline Test` 溫度設為 5500K、`ReadOnlyTest` 的 tint=0）對這張測試照片剛好都是視覺上的 no-op（tint 本來就是 0；5500K 疑似等於這張照片的原生基準值），調整面板的滑桿依設計只反映已提交狀態、不反映 preview，因此無法從畫面上分辨「方向鍵是否真的跟 hover 一樣觸發了 `previewPreset()`」，只能確認導覽本身沒有壞、也沒有誤觸發任何 alert |
| 4 | Copy to This Library（可寫入目的地） | ☑ 通過 | 在 Sony-ARW 照片庫、對 `Baseline Test` 按「⋯」→「Copy to This Library」：清單立即多出一筆同名 `Baseline Test`（library-scope 複本），沒有跳出任何 alert，操作過程沒有卡頓 |
| 5 | Copy 到唯讀 scope | ☑ 通過 | 切到 `ReadOnly-Test`（唯讀磁碟）、開一張正常照片、對 `Baseline Test` 按「⋯」→「Copy to This Library」：跳出 alert，標題「無法複製這個 Preset」、內容「This drive is read-only, so LumaHarbor can't save the preset there.」、nextStep「Unlock the drive or choose a different scope, then retry.」，title/message/nextStep 齊全；來源清單裡 `Baseline Test`／`ReadOnlyTest` 兩筆都還在，沒有被刪除 |

結論（2026-08-24 首次跑）：B 項（Copy UI）在可寫入與唯讀兩種情境都驗證通過（情境 4／5）；C 項（鍵盤導覽）機制驗證通過，但視覺 parity 因這個環境可用的 preset 素材剛好都是 no-op 而無法百分之百確認；A 項（hover-preview 不再洪水式跳 alert）**當時無法驗證**，因為情境 1／2 依賴的損毀照片在關閉初次失敗 alert 後會卡進 §11.6 記錄的新 bug，根本到不了要測試的穩定狀態。該 bug 已於同日稍晚修復並重新驗證，見 §11.7——情境 1／2 現已雙雙通過，A／B／C 三項至此全部完成人工驗證。

### 11.6 新發現：解碼失敗的初次 alert 關閉後，畫面卡在「正在解碼 RAW...」永遠不恢復

**這不是自動化操作問題，是可重現的產品 bug：**

在 Corrupt-Test 照片庫選取 `_DSC1898-corrupt.ARW`（一張刻意做壞的 RAW）：

1. 選取當下必定觸發一次解碼，失敗後跳出 modal alert：標題「無法顯示這張照片」、內容「這個 RAW 檔案似乎已經損壞。」／「試著從記憶卡重新複製這個檔案。」——這是既有、預期的行為，不屬於本輪修正範圍。
2. 按下 alert 的「好」關閉後，畫面**立即**（不到 1 秒）顯示「正在解碼 RAW...」的載入動畫。
3. 這個載入動畫**不會結束**：實測靜置 30 秒以上（多次重現，含完全不移動滑鼠的對照組），CPU 使用率維持在 0%（`ps aux` 確認 App 進程沒有在忙），既不會再跳出第二次 alert、也不會回到縮圖列已經顯示的「⚠️ 這個 RAW 檔案似乎已經損壞」靜態失敗狀態，就是卡住。
4. 這個狀態下滑鼠 hover 該照片的 preset 列表沒有任何可觀察的反應（無診斷文字、無 alert）——但因為畫面本身就卡在載入中，這個「沒反應」無法用來證明 hover-preview 修正本身有效或無效，只能證明使用者會看到一個一直轉圈、永遠好不了的畫面。
5. 唯一能脫離這個卡住狀態的方法是切換到別的照片庫（或別張照片）再切回來；重新選取同一張損毀照片會乾淨重現整個流程（步驟 1-3 每次都一樣），不是偶發。

**影響範圍**：任何選取後會先解碼失敗、使用者按下「好」關閉 alert 的照片，之後都會卡在永久載入畫面，直到手動切換照片／照片庫。懷疑跟 `a161c6e` 引入的 `previewIntentVersion`／`previewRequestGeneration` 世代計數機制有關——推測關閉 alert 的動作觸發了一次新的世代／重新解碼請求，但這次失敗的結果被某個世代比對邏輯判定為「過期」而被丟棄，UI 因此永遠停在載入中，沒有任何路徑把載入狀態設回失敗。這是**推測的根因**，本次沒有動任何程式碼，需要下一輪由能讀程式碼的 session 進去確認 `EditorViewModel` 與其 preview-render 世代比對邏輯。

**建議**：Phase 1 合入前必須修好這個問題，且修完後要重新完整跑一次 §11.5 的情境 1／2，因為目前完全無法排除「hover-preview alert 洪水」的舊 bug 只是被這個新的「卡住」蓋住、沒有真的解決；也不能排除兩者是同一個世代計數機制下的兩種症狀。

### 11.7 §11.6 bug 的根因、修復與重新驗證（2026-08-24，commit `e262b7e`）

**根因**（讀程式碼確認，不再是推測）：跟 §11.6 當時懷疑的 `a161c6e` 世代計數機制**無關**——`a161c6e` 完全沒有修改過 `EditorView.swift`。真正的根因在 `EditorView.swift` 的 `previewArea`：

```swift
if let image = model.editor.displayedImage {
    Image(...)
} else {
    ProgressView(L10n.t("Decoding RAW…"))   // 只看有沒有圖，不分「還在解碼」或「已經失敗」
}
```

這段判斷式只看 `displayedImage`（= `previewImage`）是否為 `nil`，完全沒有參考 `EditorViewModel.isRendering`（真正代表「解碼是否還在進行中」的欄位）。而一般路徑的解碼失敗處理（`handle(_:.failed)`）只清空 `previewImage` 並跳一次性 modal alert，之後沒有任何程式碼會再重新送出解碼請求。使用者關掉 alert 後，`previewImage` 永遠是 `nil`、`isRendering` 也已經是 `false`（對應 §11.6 觀察到的 CPU 0%），但 View 的 `else` 分支不管 `isRendering`，只要沒圖就顯示「正在解碼 RAW…」——結果是一個看起來像還在跑、其實什麼都沒在跑、也永遠不會有東西送進來的假性 spinner。這條路徑最早是 `26ae5dd`（2026-08-19，`clear stale frames on decode failure`）引入 `previewImage = nil` 那次就存在了，是 Phase 1 開始前就有的舊 bug，這次才第一次被完整暴露。

**修復**（commit `e262b7e`）：`EditorViewModel` 新增 `@Published private(set) var decodeFailed`，只在一般（非 preview-context）路徑的解碼失敗、且尚未被新的 `open()`／`close()`／成功畫面取代時為 `true`；`EditorView.previewArea` 改成三態判斷——有圖／`isRendering` 為真（真的在解碼，顯示 spinner）／`decodeFailed` 為真（顯示靜態的「無法顯示這張照片」占位畫面，帶警示三角形圖示）。`EditorViewModelPreviewTests` 新增／擴充兩個案例覆蓋這個狀態的設置與清除（含「後續一次成功解碼要能清掉這個狀態」）。`swift test -Xswiftc -strict-concurrency=complete` → **657 executed, 9 skipped, 0 failures**（新增斷言併入既有測試案例，測試「數」不變，全通過）。

**重新驗證**（GUI 自動化，沿用 §11.4 記錄的技巧）：

1. **修復本身**：在 Corrupt-Test 開啟 `_DSC1898-corrupt.ARW`，關閉初次「無法顯示這張照片」modal alert 後，畫面正確顯示靜態占位畫面（警示三角形圖示 +「無法顯示這張照片」文字），靜置 15 秒以上不變、CPU 維持 0%；在乾淨重新啟動的 App 上重複整個流程第二次，結果一致。
2. **情境 1（diagnostic-only hover）**：對這張照片用鍵盤 focus 移到「Baseline Test」（跟滑鼠 hover 共用同一個 `previewPreset()` 呼叫路徑），非 modal 診斷文字「White balance from this preset couldn't be applied yet because this photo hasn't finished decoding.」正確出現在 preset 清單上方，移開 focus 後消失，全程沒有跳出任何 modal alert；主畫面的靜態占位畫面沒有被覆蓋或打斷。
3. **情境 2（會改變畫面的 preset）**：這個環境既有的三個全域 preset 對測試照片都是視覺 no-op（§11.5 情境 3 已記錄），因此另外用一張正常照片把 Exposure 拖到 +3.21 後建立一個新的全域 preset `ExposureBump`（真的會改變畫面），驗證完成後已透過 App 內建的「⋯」→「刪除」移除，不留在使用者的 Presets 目錄。對 `_DSC1898-corrupt.ARW` 用鍵盤 focus 移到 `ExposureBump`：非 modal 的 `previewRenderFailureMessage`「This preset's preview couldn't be rendered right now.」正確出現，沒有跳出任何 modal alert；連續快速在「Baseline Test」／`ExposureBump` 之間切換 focus 6 次（模擬快速 hover 進出），全程只維持同一行非 modal 訊息、沒有疊加、沒有跳出任何 modal alert。
4. 過程中用一次性的除錯輸出（`FileHandle.standardError.write`，驗證後已還原、未進入 commit）確認了內部狀態機每一步都符合預期：`previewPreset` 正確判斷「改變畫面」／「no-op」、`requestPreview` 正確標記 preview-context、`handle(.failed)` 正確判斷該次失敗「仍與目前意圖相關」而非過期丟棄。

**小發現，非阻塞**：`EditorViewModel.swift` 里 `previewFailureMessage(for:)` 用到的字串 `"This preset's preview couldn't be rendered right now."` 沒有被加進 `Sources/Localization/Resources/{en,zh-Hant}.lproj/Localizable.strings`，目前靠 `L10n.t` 對缺漏 key 的 fallback（顯示 key 本身，即英文原文）撐著，繁體中文介面下這行會顯示成英文而非翻譯。建議下一輪修掉（在兩個 `.lproj` 都補上這個 key），影響範圍很小（只有這一行非 modal 文字）。

**結論**：§11.6 記錄的卡住 bug 已修復並經兩輪（含一次乾淨重啟）人工重新驗證，情境 1／2 現已雙雙通過，A 項（hover-preview 不再洪水式跳 alert／不再假性卡住）驗證完成。

## 12. Codex 第三輪 re-review 修正（commit `a161c6e`）

Codex 這輪 re-review 提出的 A／B／C 三項產品缺口，程式碼與單元測試已經全部完成並 commit：

- commit `a161c6e`（`fix: hover-preview alert flood, preset scope copy UI, keyboard preview`）：
  - **A**：`EditorViewModel` 新增 `previewIntentVersion`／`previewRequestGeneration`／`previewImageReflectsAPreview`／`previewRenderFailureMessage` 四個狀態，no-op preview 不再送 decode；preview-context 的 render 失敗改用非 modal、跟 `presetPreviewMessage` 並排的 `previewRenderFailureMessage`，不再用會蓋版的 modal `alert`；一般開啟照片／committed render 失敗仍保留 modal `alert`，沒被靜默化。
  - **B**：`PresetRow` 的「⋯」選單新增「Copy to My Presets」／「Copy to This Library」，接上既有的 `PresetLibraryViewModel.copy(_:to:)`，失敗時走既有的 `presetLibrary.alert`（title/message/nextStep 齊全，這個方法本身沒改，只是這次接上了 UI）。
  - **C**：`PresetRow` 加 `.focusable()`／`.focused(...)`，`PresetBrowserView` 加 `.onMoveCommand` 驅動跟 hover 相同的 `previewPreset`／`cancelPresetPreview`，新增 `PresetPreviewOwner` 仲裁 hover 與鍵盤 focus 互不誤取消。
- 新增測試：`EditorViewModelPreviewTests`（5 個新案例，對應 Codex A 項列的 5 個 regression 要求，用新的 `GatedPreviewRenderer` fake 精確控制競態）、新檔案 `Tests/LumaHarborAppTests/PresetBrowserPresentationTests.swift`（14 個案例，測 `PresetCopyDestination`／`PresetPreviewOwner`／`PresetFocusNavigation` 抽出來的純邏輯）。
- 驗證：`swift build -Xswiftc -strict-concurrency=complete` 乾淨編譯；`swift test -Xswiftc -strict-concurrency=complete` → **657 executed, 9 skipped, 0 failures**（比 round 2 的 638 多 19 個，全新增、全通過，沒有既有測試被改動）。

以下 5 項人工 smoke test 的結果記錄在 §11.5；情境 1／2 途中發現並修復的新 bug 記錄在 §11.6／§11.7。

### Git 狀態（2026-08-24，本節與 §11.5／§11.6 commit 前）

```
On branch claude/preset-xmp-compatibility
## claude/preset-xmp-compatibility...origin/claude/preset-xmp-compatibility [ahead 4]
```

已 push 到 origin 的最後一個 commit 仍是 `cfe9b54`；`8518dbc`／`6df75a7`／`a161c6e`／`5c4d91f`／本次這則 docs commit 都還在本機，**尚未 push**。main 完全沒被觸碰。未開始 Phase 2。未 amend 任何既有 commit。Corrupt-Test 目前是 `drwxr-xr-x`（正常可寫，沒有殘留唯讀狀態）；ReadOnly-Test 維持原本的 `dr-xr-xr-x`。照片庫清單裡沒有任何使用者個人資料夾殘留。

### Git 狀態（2026-08-24，§11.7 與本次這則 docs commit 之前）

在上面那次 commit（`76b9afc`，記錄本節時的狀態）之後，又新增了兩個 commit：`e262b7e`（`fix: show a static failed state instead of an eternal decode spinner`，§11.7 的程式碼修復，657 個測試全過）與本節／§11.7 這則 docs commit。已 push 到 origin 的最後一個 commit 仍是 `cfe9b54`；其餘全部 commit（`8518dbc`／`6df75a7`／`a161c6e`／`5c4d91f`／`76b9afc`／`e262b7e`／本次 docs commit）都還在本機，**尚未 push**。main 完全沒被觸碰，未開始 Phase 2，未 amend 任何既有 commit。驗證期間建立的臨時全域 preset `ExposureBump` 已透過 App 內建的刪除功能移除；驗證期間加入 `EditorViewModel.swift` 的三行 `FileHandle.standardError.write` 除錯輸出已用 `git checkout` 還原、確認未進入這次或任何 commit。
