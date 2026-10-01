# 白平衡與數值輸入第二輪修正驗證報告

更新：2026-10-01。狀態：**產品已有實作修正，iPad Simulator 主要路徑通過；26 項完整驗收仍因實體 iPad 與色差／拒絕矩陣未完成。**

## 起點、所有權與證據界線

- 產品工作樹：`codex-open-source-release-prep`；branch `codex/open-source-release-prep`；HEAD `8b8afa4ba2deb9a275234591f6493cb44ef047a0`，未變更。
- 起點有 56 個 dirty/untracked 項目。以本輪開始保存的 Sources/Tests 快照區分既有變更；沒有整檔回復、刪除或覆蓋無關工作。
- 曾由 core 子代理先補測試；該代理因額度錯誤停止並已中止，之後由主代理單一寫入。本次沒有兩個代理同時編輯同一檔案。
- 未改 signing、未 commit、未 push、未 merge、未 rebase。signing 檔案與起點 SHA-256 相同，僅本機比對，不在報告列私人設定。
- 環境：macOS 26.7.1／Apple Silicon；Xcode 26.6 (17F113)。原生 UI 測試在 XCTest 內建立不顯示的 NSWindow，引用當前產品元件；沒有再啟動 LumaInputHost App。
- [本輪 follow-up spec](../../../../docs/superpowers/specs/2026-09-29-white-balance-and-input-review-followup-spec.md)、[原 26 項修正规格](../../../../docs/superpowers/specs/2026-09-29-white-balance-and-input-correctness-repair-spec.md)。不宣稱 Lightroom 像素一致、灰卡校準完成或可合併。
- 原報告的 100 focused／1981 full／9 skipped／1 failure 為歷史證據，不代表此版本。原先「需要使用者提供可控 renderer」與「只差可重新啟動的宿主」的說法已撤回：本輪已自行完成可控 renderer/histogram 與不開外部 App 的真實 TextField 測試。

## A～F 與 RF-01～06

| 階段／缺陷 | 產品修正與實際證據 | 未完成界線 |
| --- | --- | --- |
| A：先重現 | 保留 baseline、分支及 signing 比對；下表列出產品 RED→GREEN，不以編譯錯誤或宿主崩潰冒充產品重現。 | 新增 iPad 缺欄位的檢查屬接線 contract，不能當 iPad 手勢驗收。 |
| B：RF-03／05 | 新 Temperature 寫入與最後 delta 均依照片 baseline 限幅；native/XMP 缺能力保留原葉並診斷；session NaN 保留權威值，直接 decoder 非有限 Tint 明確拒絕；保留有限 legacy raw 值。clamp diagnostic 跨 commit/render 保留。 | 真實灰卡準確度另列 TINT-02/PARITY-01。 |
| C：Tint | 保留既有修正方向及 saved/local Tint 映射；純色方向、native decoder、持久化回歸通過。 | 四色偏實拍 ROI 尚缺。 |
| D：RF-01／04 | gesture 綁 photo/revision/source generation；過期 ended 不可重建候選。frame context 在 actor hop 前註冊；成功、失敗、histogram 都核對 edit/intent。只在實際 bitmap recipe 相符時重用；no-op reset 可安全重綁。手動控制完成順序驗真正像素、完整 bins、save spy。 | 真實滑鼠／觸控 overlay 的完整矩陣未跑。 |
| E：RF-02 | 以明確草稿狀態與 AppKit/UIKit bridge 取代舊同步旗標／延後修補。Enter/blur 一次結束、Escape 取消、精確值不被顯示精度量化；live context reader 在 SwiftUI 更新前也能拒絕舊草稿。所有共用 panel 接線；八語系錯誤文字含範圍與 K。 | macOS 鍵盤／delegate 實測通過；雙擊另有明確 SKIPPED，iPad 實際觸控未跑。 |
| E：iPad 接線 | 兩個 iPad 色彩入口補回 Temperature/Tint/Vibrance/Saturation，並共用 44 pt 滴管按鈕；畫布 overlay 固定影像／取樣 context，拖曳 preview、放開單次 commit，啟用時停用縮放。iPad Simulator 已操作有效輸入、越界提示、啟用／取消／取樣、Undo／Redo、重啟持久化與直／橫向版面。 | 實體 iPad、VoiceOver、Apple Pencil／外接鍵盤、全部拒絕原因與移出影像矩陣仍未執行。 |
| F：RF-06 | 重建以下 26 項矩陣，保留歷史反證、更正誤報，區分 PASS／FAIL／SKIPPED／NOT RUN。 | 必測子條件未完成時，不用「PASS（核心）」包裝整項。 |

### 行為紅燈與反轉證據

全部日誌位於被 Git 忽略的 [本機 evidence 目錄](../../../.build/repair-evidence/2026-09-30/)；其私人 fixture 路徑與原始輸出不可提交。

| 重現 | RED 證據 | 修正後證據 |
| --- | --- | --- |
| 明確輸入 4537 被誤認未改、精確 draft 變成捨入顯示 | `input-native-red-sync.log`：原生欄位失敗；其中 Escape selector 的 unexpected error 是宿主錯誤，不計產品 RED | `native-preset-matrix.log`、`native-sidecar.log`、最終 focused/full |
| 新 set/update 未按 baseline 限幅、NaN 改成 0、nil baseline 可套 native/eyedropper | `core-red.log`：6 tests、28 failures | `core-boundary-green.log`：6/0；最終 WB/preset/decoder suites |
| 過期 release 重建候選、clamp warning 在 commit/frame 消失 | `gesture-diagnostic-red.log`：2 tests、6 failures | `repair-focused-green.log`、最終 WhiteBalanceWriteBoundaryTests |
| 舊候選 frame 在外部曝光調整後仍可發布 | `deferred-red.log`：1/1 failure | `deferred-matrix.log`：4/0，含兩種還原及 15 種晚到結果組合 |
| 同值重設後真實欄位仍提交舊 draft | `panel-context-red.log`：1 test、3 failures，曝光變成 1.5 且新增 Undo | `panel-context-green.log`、最終 native matrix；立即 Enter 不等 UI 更新亦通過 |
| no-op reset 令來源永遠不匹配；未完成新 render 仍可用舊 frame 建候選 | `frame-matching-red.log`：2 tests、4 failures | `frame-matching-green.log`：72/0 |
| 直接 RAW request 非有限 Tint 被默認 0 | `decoder-tint-red.log`：1 test、3 failures | 最終 RawDecodingTests、真實 RAW 非有限 request 測試 |
| 新 Temperature set/update 的 clamp diagnostic 消失 | `write-diagnostic-red.log`：1 test、3 failures | `write-diagnostic-green.log`：41/0 |
| iPad 色彩頁沒有白平衡欄位 | `ipad-wiring-red.log`：1 test、4 接線 failures | `ipad-wiring-green.log`：8/0 及 device/Simulator build；不是觸控驗收 |

初期非同步 XCTest/AppKit 宿主錯誤保留在 `input-native-red.log`，後改為同步 main-thread native harness。它不是產品 bug 的失敗證據。本輪未修改 signing 來消除測試失敗。

## 最終驗證命令與結果

以下從產品工作樹執行。RAW 環境值指向既有、忽略追蹤的 Sony fixture 目錄；公開報告只列佔位符，不列私人檔名／digest。

```sh
LUMAHARBOR_RAW_FIXTURE_DIR=<local-private-fixture-directory> swift test
swift build -Xswiftc -strict-concurrency=complete
xcodebuild -quiet -project Apps/LumaHarborPad.xcodeproj -scheme LumaHarborPad -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -quiet -project Apps/LumaHarborPad.xcodeproj -scheme LumaHarborPad -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
git diff --check
```

Focused filter（同樣設定 RAW fixture）：

```sh
swift test --filter 'WhiteBalancePresentationTests|WhiteBalanceEyedropperTests|WhiteBalanceWriteBoundaryTests|RawDecodingTests|RawFixtureTests|PresetApplicatorTests|EditorSessionEditingTests|EditorSessionDocumentPersistenceTests|EditorSessionEyedropperRenderingTests|EyedropperDeferredResultTests|AdjustmentValueInputTests|AdjustmentValueInputNativeTests|AdjustmentInputStateTests|PadWhiteBalanceWiringTests|PhotoAdjustmentsTests|SidecarRepositoryTests'
```

| 執行 | 結果／退出碼 | 證據 |
| --- | --- | --- |
| 完整 suite，含私有 RAW | **FAIL**：2027 executed，1 skipped，1 failure；exit 1。唯一 failure：`AppIconAssetContractTests.testIPadProjectDoesNotContainPersonalBundleIdentifier`，既有 signing contract 的 `0 != 2`，已單獨重跑確認，沒有新增產品 regression failure。 | 2026-10-01 推送前完整重跑；先前紀錄見 [full-final.log](../../../.build/repair-evidence/2026-09-30/full-final.log) |
| Focused | 213 executed，212 通過，1 skipped，0 failures；exit 0。不把 skip 算成通過。 | [focused-final.log](../../../.build/repair-evidence/2026-09-30/focused-final.log) |
| 原生欄位 suite（full 內） | 12 executed，11 通過，1 skipped，0 failures。INPUT-01 的照片／sidecar 檢查使用真正 EditorSession 與 FileSidecarRepository。 | 同上 full；另見 `native-sidecar.log` |
| baseline 說明文字測試穩定性 | **PASS**：hidden `NSHostingView` 不會把 SwiftUI `Text` 暴露成可由 AppKit children 遍歷的 accessibility tree；改由 `BasicAdjustmentPanelModel` 提供狀態→本地化說明的單一資料來源，產品畫面直接使用同一結果。專項 1/1 PASS。 | `AdjustmentValueInputNativeTests.testTemperaturePanelDisablesMissingInvalidBaselinesAndRecoversWithoutWriting` |
| 草稿狀態／WB 邊界／受控非同步 | 7／11／4 tests，皆 0 failures；非同步套件內包含 18 個受控情境。 | 同上 full |
| 真實 RAW suite（full 內） | **11 executed／0 skipped／0 failures**。新增直接 2000/50000、非有限 request、PNG 匯出越界/有效 recipe 對照；原 RAW bytes/fingerprint/mtime 回歸。 | 同上 full；`raw-and-persistence.log` |
| Strict-concurrency＋macOS build | exit 0；`swift build` 同時編譯／連結 LumaHarbor。 | [strict-build.log](../../../.build/repair-evidence/2026-09-30/strict-build.log) |
| iPad generic device build | exit 0；不簽章，未改 project signing。 | [ipad-build-final.log](../../../.build/repair-evidence/2026-09-30/ipad-build-final.log) |
| iPad generic Simulator build | exit 0；build 不等於操作 Simulator。 | [ipad-simulator-build.log](../../../.build/repair-evidence/2026-09-30/ipad-simulator-build.log) |
| 差異格式／signing | `git diff --check` exit 0；signing 檔案與起點雜湊相同。 | 本機檢查 |
| iPad Simulator 操作 | **PASS（主要路徑）**：iPad Pro 11-inch (M4)、iOS 18.6。真實 RAW 開啟後，色溫 5000 可提交；99999 被拒絕並保留 5000，accessibility help 顯示 2000–50000 K；滴管可啟用／取消，取樣後 5000/0 → 2000/+8，顯示範圍診斷；Undo 回到 5000/0、Redo 回到 2000/+8；App 重啟後仍為 2000/+8；直向 popover 與橫向 sidebar 均可操作。 | 前景 Simulator 與 accessibility tree／畫面觀察；測試文件以公開 `PhotoDocumentStore` API 預先建立，系統 Files picker 不列入本項。 |
| iPad Info 橫向版面 | **PASS（回歸修正）**：新增整理控制時，固定 120 pt 評分標籤＋六顆 32 pt 按鈕把 320 pt dock 撐寬，造成整頁左右裁切。改為評分標題與按鈕上下排列後，橫向直方圖、Save State、File Info、整理、評分、旗標與關鍵字均完整對齊；直向展開面板亦正常。 | TDD RED 1 test／2 assertions；GREEN `PadBatchContractTests` 7/7；Simulator 重建、安裝與前景畫面確認。 |
| 實體 iPad 操作 | **NOT RUN**：inventory 中的 iPad 當時為 unavailable。 | 不以 Simulator 結果冒充實體裝置。 |

RAW preview 的最後 full 量測：cold 約 149.6 ms，warm 約 146.8／146.0／145.9 ms；這不是 30 次 p95 比較，不能宣稱效能 gate 或所有操作低於 150 ms。其他執行曾有 warm 約 198 ms，未隱藏此差異。

### 唯一 SKIPPED 的原因

`testDoubleClickSelectsNativeNumericTextWithoutResettingTheParentRow` 先用**不含產品元件或 SwiftUI reset gesture 的普通 NSTextField**校準合成滑鼠事件。隱藏 NSWindow 的該對照欄位也未產生選字，故不能據此指控或證明產品雙擊行為；保留 `native-double-click.log`，跳過真正產品雙擊斷言。需要前景產品視窗的滑鼠／觸控驗證。其餘原生 insertText、Enter、Escape、blur、焦點、controller nudge 均確實執行，不因這一項 skip 而省略。

## 26 項完整驗收矩陣

原規格每列條件完整保留。此處 INPUT 的 PASS 是已執行的 macOS 原生事件；跨平台要求獨立列在 PARITY-02。PASS 只代表該 ID 列明條件，不代表整份 UI spec 或 Lightroom parity。

合計：16 PASS／9 NOT RUN／1 FAIL。測試套件中的 1 項 SKIPPED 記在 INPUT-05 備註，不算驗收通過。

| ID | 原規格完整條件 | 結果 | 本輪證據與仍缺條件 |
| --- | --- | --- | --- |
| WB-01 | 核心：baseline 2000、4536.72802734375、5500、10000、50000；測端點、端點內外及相對 offset 邊界；最終 Kelvin 有限且合法 | PASS | WhiteBalancePresentationTests＋testFinalDeltaResolutionMatrixUsesIndependentKelvinBounds：五種 baseline × 五種起點 × 三種 delta，共 75 組，獨立公式驗最終 offset/Kelvin。 |
| WB-02 | 核心＋decoder：重播 F1 的 offset 與 RGB `(0.6, 0.5, 0.4)`；解析後 UI／實際 decoder 值一致，不能出現負 Kelvin | PASS | F1 decoder resolver 與固定 RGB 測試；RawFixtureTests 的實際解碼端點像素相等證據。此 ID 不代表原介面 spec 的灰卡／Lightroom 色差關卡。 |
| WB-03 | 核心：Kelvin／offset 往返誤差及 Float／整數顯示容差符合 §5.1；不可用 UI 整數值取代精確模型值 | PASS | Double 往返、Float 0.01 K、整數顯示與原生欄位 4536.72802734375 未改輸入／明確輸入 4537 分開驗證。 |
| WB-04 | 核心＋UI：baseline 未就緒、NaN、Infinity、非正或範圍外；不偽造 Kelvin、不錯誤提交；能力恢復後重新解析 | NOT RUN | 核心非法 baseline 矩陣及真實欄位消失→恢復 4537、零寫入已通過；loading/unavailable/invalid 各語系實際可見文字與所有提示的 UI 檢查尚未完整執行。 |
| WB-05 | 整合：直接 RAW request／背景匯出繞過 View，越界仍受控；2000／50000 端點可解碼且無非法 assignment | PASS | RawFixtureTests.testDirectRawRequestsClampToRealKelvinEndpointsAndRejectNonFiniteValues、testPreviewAndBackgroundExportUseTheSameWhiteBalanceEndpointLimits：直接解碼、實際 PNG 匯出端點與越界像素相等，RAW bytes 不變。 |
| WB-06 | sidecar：合法舊檔往返不改數字與合法渲染；越界舊檔只開啟不寫入，警告與有效值一致；非 WB 編輯不偷偷遷移 | PASS | SidecarRepositoryTests 保留 bytes；PhotoAdjustmentsTests 保存有限舊值；session 文件測試驗非 WB 編輯後仍儲存 -2000、初始警告／unchanged 正確；合法數值既有回歸通過。 |
| WB-07 | session＋sidecar：越界舊檔的明確 WB 編輯→Undo→Redo→重開；原始／有效值、警告與一次操作歷史全部符合 §5.4 | PASS | EditorSessionDocumentPersistenceTests.testLegacyWhiteBalanceEditUndoRedoSaveAndReopenPreserveTheRightRawValue：真實文件 store，WB 編輯／Undo／Redo／重建 store，原始值、有效值、警告、Tint 與曝光均核對。 |
| WB-08 | preset＋整合：原生相對／XMP 絕對預設集，分別測合法、越界、缺 baseline；預覽與提交結果一致，診斷不遺失 | PASS | WhiteBalanceWriteBoundaryTests.testNativeAndXMPPresetPreviewCommitAndDiagnosticsAgree：native/XMP、合法／上下越界、nil/NaN baseline，preview/commit/alert 一致；一次 Undo 還原。 |
| TINT-01 | 核心：偏綠正 delta、偏洋紅負 delta、中性零 delta；不能沿用錯誤的既有負號斷言 | PASS | WhiteBalanceEyedropperTests：偏綠正、偏洋紅負、中性零與兩軸獨立；本輪未反轉既有 native 映射。 |
| TINT-02 | 真實 RAW：固定 ROI 與非邊界測例，四色偏逐一符合 §6 的 E 改善；固定 Temperature 的 ±Tint 渲染方向正確 | NOT RUN | 缺固定受控灰卡 ROI／四色偏實拍資料；現有 Sony RAW 不是已標定灰卡，不聲稱 E 改善或 D65 Lab 色差達標。 |
| TINT-03 | 相容性：舊 saved Tint、局部 Tint 與預設集數值及既有映射不反轉；重設不波及其他參數 | PASS | PhotoAdjustments／AdjustmentMapping／local-adjustment／preset 回歸及 session Tint=12 跨 Temperature 編輯與持久化保持不變；未修改既有 saved/local Tint 映射。 |
| INPUT-01 | 真實 UI：6500→60000→Enter→焦點移到 Tint；欄位回6500並顯示範圍，slider／照片／sidecar皆維持6500 | PASS | macOS testActualKelvinPanelRejects60000BeforeTintFocusWithoutChangingPixelsOrSidecar：真實 BasicAdjustmentPanel Temp/Tint、native insertText/Enter/移焦，6500 回復、模型／預覽像素／Undo／sidecar bytes 不變。 |
| INPUT-02 | 狀態＋UI：空字串、文字、NaN、Infinity、只輸入符號、上下限外；Enter／失焦均不提交且提示持續 | PASS | macOS 真實欄位 9 種無效字串 × Enter/blur：空、abc、NaN、±Infinity、單獨 ±、上下越界；可見 error label 與 accessibility help 含 2000–50000 K，setter 零次。 |
| INPUT-03 | 狀態＋UI：有效值 Enter 再失焦只提交一次；Escape 零提交；未改草稿失焦不量化4536.72802734375等精確值 | PASS | macOS 真實欄位：合法 Enter+blur 一次，Escape 零次，未改精確值零次，明確輸入 rounded value 一次；state/controller 測試補事件順序。 |
| INPUT-04 | 狀態＋UI：草稿期間 reset／Undo／Redo／slider更新／換照片，舊失焦事件不能覆寫新權威值 | PASS | macOS 真實產品欄位重設／Undo／Redo／slider／preset／同值換照片；刻意不等 SwiftUI reconcile 就送 Enter，舊草稿不能覆寫。所有共用 panel 已接同一 context reader。 |
| INPUT-05 | macOS＋iPad：數值雙擊選字、增減邊界、有效／無效草稿後增減、錯誤 accessibility、窄版與44 pt觸控不退化 | NOT RUN | 真實 native draft→nudge 與精確步距／邊界／accessibility 範圍已通過；隱藏視窗雙擊校準對普通 AppKit 欄位也失敗，該測試 SKIPPED。iPad 觸控、窄版、VoiceOver 實際操作仍未跑。 |
| EYE-01 | session＋UI：tooDark／clipped／outOfRange／nonFinite 取樣後 release，提示保留、工具啟用、無歷史或存檔 | NOT RUN | 核心 sample reasons／session release 保留原因、零歷史已通過；真實 overlay 的全部拒絕原因、release 與工具啟用狀態尚未完整操作。 |
| EYE-02 | session＋UI：有效→無效→release，不能提交先前有效值；下一次有效取樣或取消後清除舊錯誤 | NOT RUN | session 有效→無效→release、下一有效／取消清除錯誤已通過；真實滑鼠／觸控 overlay 路徑未驗收。 |
| EYE-03 | 可控 renderer：重播 F5：非中性候選→中性→release／cancel；實際 CGImage 像素及 histogram 回到基準，無新增 Undo | PASS | EyedropperDeferredResultTests.testNeutralReleaseAndCancelRestorePixelsAllBinsAndDoNotSave：release、cancel 兩分支，實際 CGImage red 220→100、完整 768 bins、recipe、Undo 與 save spy 全部核對。 |
| EYE-04 | 可控排程：舊 render 延遲到中性／拒絕／取消／換照片之後才完成；舊影像、histogram、錯誤皆被拒絕 | PASS | 手動控制 continuation：舊成功、舊失敗、舊 histogram 分別在 neutral／invalid／cancel／external edit／photo switch 後完成，均不覆蓋；另有 RF-01 同步重放及 frame-matching 測試。 |
| EYE-05 | session＋UI：有效改值取樣只產生一筆 Undo；Undo／Redo／重開可重現最終有效值；preview 階段零 sidecar 寫入 | PASS | session＋實際 PhotoDocumentStore 已驗 preview 零儲存、commit 一筆 Undo、重複 release 不提交。iPad Simulator 真實 overlay 取樣把 5000/0 改為 2000/+8；一次 Undo 回到 5000/0、Redo 回到 2000/+8，App 重啟後仍為 2000/+8。 |
| EYE-06 | session＋UI：拖曳中來源 frame 更新、移出圖片或無像素、preview失敗後取消；不累加錯基準、不誤提交、不殘留成功狀態 | NOT RUN | overlay 已固定 image/frame/token 並先檢查圖內座標；session 拒絕舊 frame／舊 gesture，延遲 failure 測試通過。來源變化、無像素與 failure→cancel 的全部真實手勢尚未驗收。 |
| PARITY-01 | 整合：相同 recipe 的 preview／export 使用相同 WB 解析與診斷；像素驗證方法及容差依原規格 WB-02，未量測即 NOT RUN | NOT RUN | 已驗 preview 與實際 export 各自把 raw 越界 recipe 解析成相同 endpoint 像素；尚未以指定縮放／D65 Lab／ΔE00 流程比較 preview 與 export ROI，不能以端點相等替代色差量測。 |
| PARITY-02 | 跨平台：macOS、iPad Simulator 及實體 iPad 重播數值輸入與滴管主要路徑；操作結果／儲存語意一致 | NOT RUN | macOS 原生欄位與 iPad Simulator 主要路徑已驗；Simulator 的有效／越界輸入、滴管取消／提交、Undo／Redo、重啟持久化均符合共用 session 語意。實體 iPad 當時 unavailable，因此整個跨平台項目仍不能標 PASS；先前「iPad 無入口／手勢」的產品 FAIL 已修正。 |
| REG-01 | 全套：完整測試、RAW suite、strict-concurrency、macOS及iPad build；保留已知失敗與所有 skip，零新增失敗 | FAIL | 完整 suite 2027 executed／1 SKIPPED／1 既有 signing contract failure；RAW 11/11，strict/macOS 與兩種 iPad build 通過。保留 failure，不變更 signing。 |
| REG-02 | 手動＋完整性：Solo／Geometry／filmstrip／曝光代表性回歸；RAW前後checksum相同，無非預期sidecar寫入 | NOT RUN | RAW bytes/fingerprint/mtime、sidecar 無非預期寫入與既有曝光／Geometry／filmstrip/Solo 自動回歸通過；最新產品人工代表性巡檢未完整執行。 |

## 本輪修改範圍（相對起點快照，不是整個 dirty diff）

- AdjustmentUI：新增 `AdjustmentInputState`、`AdjustmentInputController`、`AdjustmentNativeTextField`、`AdjustmentEditingContext`；修 `AdjustmentValueInput`、`BasicAdjustmentPanel`，以及 Color/Detail/Effects/Geometry/Local 的 context 接線。
- EditorCore：`EditorSession` 的 WB capability、revision、候選及 frame/histogram 意圖、寫入限幅及 diagnostic。
- RawProcessingCore：`WhiteBalancePresentation` capability、`WhiteBalanceEyedropper` 最後解析、`CoreImageRawDecoder` 非有限 Tint 防線、`PreviewRequest/PreviewScheduler` 的 ephemeral contextID。
- PresetCore：native Temperature 缺 baseline 拒絕並保留原葉；不放寬能力判定來迎合舊 fake。
- LumaHarborApp：`EyedropperOverlayView` 綁定固定 context、拒絕 stale frame；`WhiteBalanceEyedropperButton` 無能力時停用。
- iPad：`PadInspectorHost` 與 `PadEditorView` 掛回色彩基本欄位與共用 44 pt 滴管入口；新增畫布取樣 overlay、固定 context、preview／commit／cancel 與滴管期間停用縮放。沒有修改 Xcode project。
- 八語系補有限數字、範圍、loading/unavailable/invalid、clamp、stale-frame 說明。
- 測試：新增 native/state/context/延遲控制套件；修舊 fake baseline、以 controller 行為替代失效的 source-string input 斷言；RAW、持久化與 preset matrix 補強。其他既有 dirty 的 renderer/filmstrip/inspector 等檔案保持起點內容。

## 尚需完成與最小協助

1. **仍需產品開發**：iPad 沒有滴管入口／畫布手勢。不要把「UIKit 欄位已編譯」誤寫成 iPad 滴管已修好。下一個有界工作應共用既有取樣 snapshot/context 路徑，接入 iPad 畫布，再驗實際觸控與取消。已向使用者提出共用元件、44 pt 入口／取消及取樣時暫停縮放的設計，待確認後實作。
2. **仍需前景 UI 驗收**：Mac 真實雙擊／完整 overlay 手勢，iPad Simulator／實體 iPad 的軟體與外接鍵盤、±、44 pt、窄版、VoiceOver。若要避免再次干擾使用者桌面，先約定可操作的隔離圖庫與裝置，不再以反覆開啟臨時 LumaInputHost 代替。
3. **缺資料的真正色彩關卡**：需要固定灰卡 ROI、暖／冷／綠／洋紅非邊界實拍案例，以及 preview/export 相同轉色與縮放基準；現有單一 Sony RAW 不能替代這些資料。
4. **既有明確限制**：使用者禁止改 signing，故保留 full suite 的唯一 signing contract failure。本次只依明確授權 commit／push 到新的 `codex/` 分支，不 merge／rebase，且不納入 signing-only project 差異。

不能使用「spec 開發全部完成」、「26/26 PASS」或「白平衡準確度已校準」作為本次結論。已完成的是上列產品修正與可重現的核心／原生欄位驗證。
