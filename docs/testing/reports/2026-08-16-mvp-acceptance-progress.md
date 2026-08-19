# LumaHarbor Mac-first MVP 人工驗收進度筆記（2026-08-16，未完成，交接用）

> 這不是正式驗收報告（`docs/testing/mvp-acceptance-report-template.md` 是正式格式），是當天做到一半、明天接續用的進度快照。寫這份筆記的原因：跨工具/跨 session 交接不能只靠 Claude 私有 memory，要寫進專案內文件（見使用者過去的交接慣例）。
>
> 對應 spec：[`2026-08-15-mac-first-mvp-acceptance-plan.md`](../../superpowers/specs/2026-08-15-mac-first-mvp-acceptance-plan.md) Gate D/E/F。

## 目前 git 狀態（2026-08-16 當天結束時）

- 分支：`main`
- 本機 HEAD：`d2e0e11`，比 `origin/main`（`18faff9`）領先 **2 個尚未 push 的 commit**：
  - `bb92349` — 加入繁體中文本地化（跟隨 macOS 系統語言，`.lproj/Localizable.strings`，不是 UI 內建切換器）
  - `d2e0e11` — 更新 README（反映 MVP 已可用、新增「Running it」章節，Acknowledgements 沒動）
- `?? docs/reference/` 仍是未追蹤狀態，**不要動它**（使用者/Codex 先前明確要求原樣保留；裡面現在有兩份筆記：`awayphotoraweditor-design-notes.md` 跟 `next-phase-scope-notes.md`）
- 自動化驗收（`Scripts/run-mvp-acceptance.zsh`）在這個 HEAD 上完整跑過，Overall PASS（strict build / 332 tests 0 failures / RawFixtureTests 8/8）

## 測試用資料

- `Fixtures/Private/APFS-Test`：6 張 fixture 副本（來自 `Fixtures/Private/Sony-ARW`）
- `/Volumes/Untitled/LumaHarbor-exFAT-Test`：11 張（6 張同上 + 5 張從使用者相機記憶卡 `/Volumes/Untitled/DCIM/100MSDCF` 額外複製，**都是複製，原始檔／記憶卡沒動過**）

## Gate D／E／F 進度

### 已完成
- App 能正常開啟（`swift run LumaHarbor` 或 Xcode ⌘R；一開始卡在「只有 Build Succeeded、沒有 Running」是使用者只按到 Build 沒按到 Run，已排除）。
- 初次啟動畫面正確（規格 §6.1「加入照片資料夾」畫面）。
- **APFS 資料夾**：
  - 用 ⌘⇧G 導覽到測試資料夾、加入成功。
  - 縮圖有增量出現（不是全部同時跳出來）。
  - 點照片、拉滑桿，畫面會跟著變（但延遲明顯，見下方效能問題）。
  - **完全關閉 App（⌘Q）後重開，重新選同一資料夾，剛剛調整的滑桿數值有正確保留**（使用者原話「有都有在」）——這代表 sidecar 自動保存＋重啟後恢復這條路徑是通的。

- **exFAT 資料夾**（2026-08-17 補測，`/Volumes/Untitled/LumaHarbor-exFAT-Test`，11 張）：
  - 加入資料夾成功、縮圖增量出現、拉滑桿有反應（延遲跟 APFS 一樣，屬於同一個已知效能問題，非 exFAT 特有）、完全關閉 App 重開後滑桿數值有保留。**4 項行為跟 APFS 完全一致**。
  - 過程中另外踩到一個 Xcode 操作雷：scheme 選單預設停在 `LumaHarbor-Package`（umbrella scheme），按 Run 只會 build 不會真的啟動 App，跟筆記原本記的「只按到 Build 沒按到 Run」是不同根因但同一種症狀（Build Succeeded、沒有 Running）。改選 `LumaHarbor` scheme，或改用 `swift run LumaHarbor` 可繞開。

- **改名 relink**（Gate E 第 6 項，2026-08-17 補測，用 `Fixtures/Private/APFS-Test`）：關閉 App→Finder 改名資料夾→重開 App，下方自動跳出 **Reconnect** 提示，點下去後確認：之前調過參數的照片調整值還在、沒有變成重複的 library 項目。**通過**。

- **刪除本機 SQLite/cache 重建**（Gate E 第 5 項，2026-08-17 補測）：關閉 App→刪除 `~/Library/Application Support/LumaHarbor/library.sqlite`（含 `-wal`/`-shm`）與 `cache/thumbnails/`、`cache/previews/`（保留 `bookmarks/` 未動）→重開 App。App 自動重新掃描、縮圖重新生成，之前調過參數的照片調整值還在（未回報有重複或對不起來的照片）。**通過**。

### 尚未做（明天從這裡接續）
- **拔插 SSD**（Gate E 第 7、8 項）：2026-08-17 本輪先跳過，之後要補測——exFAT 隨身碟開著時直接拔掉、確認不 crash、縮圖還在；重新插上、重新授權、確認資料沒丟。
- **唯讀資料夾情境**（Gate E 第 9 項）：目前還沒有唯讀測試目錄/disk image，需要先準備。
- **壞掉的 RAW/sidecar**（Gate E 第 10 項，2026-08-17 測過，**發現問題，見下方新增的 P1/P2**）。
- **Gate F UI 功能矩陣**：原圖比較、Undo/Redo、切照片前存檔、匯出流水號與取消暫存檔清理、各種錯誤情境提示——都還沒系統性走過。
- **Gate F 效能**：Instruments 沒接（這台機器目前用肉眼判斷），且已經發現一個真實效能問題（見下）。

## 發現的問題（P1，效能，已找到根因，尚未修）

**現象**：拉調整滑桿（例如曝光）時畫面更新明顯不即時，使用者實測約 3 秒延遲。規格 §11 目標是 ≤150ms。

**已確認的根因**（讀過 `EditorViewModel.swift` / `PreviewScheduler.swift` / `CoreImagePreviewRenderer.swift`）：
- 每次滑桿數值變化（`setAdjustment`）都會立刻送出新的 `.interactive` 品質預覽請求，沒有節流（throttle）。
- `PreviewScheduler.submit()` 有正確做「新請求取消舊請求、畫面只顯示最新結果」（`isCurrent` token 機制沒問題）。
- 但實際的 RAW 解碼（`decoder.decode(decodeRequest)`，在 `CoreImagePreviewRenderer.render()` 裡）**是不可中途打斷的單一呼叫**——`Task.cancel()` 只能讓「已經開始解碼」的舊工作在解碼完成後被丟棄（不顯示），不能真的提早停止那次解碼本身消耗的時間。
- 結論：如果使用者拖曳滑桿的頻率比一次互動品質解碼還快，請求就會像排隊一樣越積越多，累積出使用者看到的秒級延遲——不是「取消機制沒做對」，是「解碼工作本身不可搶佔，純靠取消結果無法真正省下已花的時間」。

**還沒做**：修正方案（例如在送出請求那端加節流／debounce，而不是只靠接收端取消；或是降低 interactive 品質的目標像素讓單次解碼更快）需要先跟使用者確認要哪種修法，還沒動手。

## 發現的問題（P1，損壞 RAW 顯示偽成功，Gate E 第 10 項，2026-08-17 新發現，尚未修）

**測試素材**：`Fixtures/Private/Corrupt-Test/`，3 張複製檔（原始檔未動）——`_DSC1896-good.ARW`、`_DSC1897-good.ARW` 正常；`_DSC1898-corrupt.ARW` 用 `head -c 2048` 截斷成 2KB，不是合法 ARW 結構。另外預先放了一個內容是無效 JSON 的 sidecar `.lumaharbor/edits/BAD-SIDECAR-DEADBEEF.json`。

**現象**：
- 點開損壞的 `_DSC1898-corrupt.ARW`（在使用者操作裡對應「98」）時，畫面**完全沒有任何錯誤提示**，安靜地顯示跟前一張（97）相同的圖——即舊預覽畫面沒有被替換，看起來像是成功解碼，但其實是解碼失敗後 UI 沒有更新或沒有清空舊畫面。**這違反 Gate E 的核心通過條件之一：「不能顯示偽成功」**（規格原本這句是寫在唯讀情境，但同一原則適用於任何失敗情境）。
- App 本身沒有 crash，兩張正常照片（96、97）都能正常瀏覽，掃描本身有繼續（沒有整個卡死）。
- 額外觀察：第一次點 96 時畫面持續 loading 不出來，點了 97（正常）、98（損壞、顯示 97 殘影）之後**再點回 96，這次才正常出現**。目前不確定跟損壞檔案是否有關，還是純粹是首次解碼較慢；需要之後單獨用一個沒有損壞檔案的資料夾重現排除。
- 損壞的 sidecar（`BAD-SIDECAR-DEADBEEF.json`）：**沒有被改名／移動／隔離**，測試後檔案還在原位、內容原封不動（用 `ls -la` 確認 mtime 沒變）。App 沒有覆寫它，但也沒有任何「隔離」的可觀察行為——不確定是 App 真的有內部隔離機制只是沒有 UI 呈現，還是根本沒有處理這個檔案、單純沒讀到就跳過。使用者在編輯另一張照片時，App 有正常新建一個獨立的 edit json（`C3BDC256-....json`），代表正常 sidecar 讀寫路徑沒被壞檔卡住。

**尚未做**：
- 確認損壞 RAW 顯示偽成功是 UI 層沒清空舊 preview，還是 decode 失敗後的錯誤沒有往上傳遞（需要讀 `CoreImagePreviewRenderer` 錯誤處理路徑跟 `EditorViewModel` 怎麼接收 decode 失敗）。
- 確認損壞 sidecar 到底有沒有被讀取／隔離機制處理，或只是被忽略。
- 重現「首次點擊 loading 不出來、切別的再切回來才正常」是否為獨立 bug。

## 明天可以問使用者的問題（決定從哪接續，2026-08-16 當天寫）

1. 先把效能問題修掉，還是先把 Gate D/E/F 剩下的人工步驟（exFAT、拔插 SSD、唯讀、壞檔、relink、Gate F 矩陣）走完？
2. 效能問題修法要選哪種：送出端加節流（簡單、但可能讓最新一次調整感覺稍有延遲）、還是先降低 interactive 品質的目標尺寸讓單次解碼更快（複雜一點，但更貼近「即時」的體感）？
3. 兩個尚未 push 的 commit（`bb92349` 本地化、`d2e0e11` README）要不要先 push？
4. `docs/reference/next-phase-scope-notes.md` 裡記的下一階段範圍（風格檔雙軌、批次/單次全格式匯出）——MVP 簽收後要不要就照那份筆記直接開新 spec？

## 2026-08-18 這次 session 做的事（尚未 commit，交接用）

**兩個 P1 都已經寫了修法（working tree 未提交）：**
- `Sources/LumaHarborApp/ViewModels/EditorViewModel.swift`：新增 `interactiveThrottleInterval`（80ms）節流，`setAdjustment` 觸發的 interactive preview 改走 `requestInteractivePreview()`，超出節流下限的請求會被 debounce 成一次、取最後的值；decode 失敗時 `previewImage = nil`（修掉偽成功殘影）。
- `Sources/LumaHarborApp/Views/EditorView.swift`：把 `model.editor.alert` 接上真正的 `.alert(...)`，失敗訊息現在會顯示給使用者（之前這條路徑存在但沒接 UI）。

**新增回歸測試（`Tests/LumaHarborAppTests/EditorViewModelPreviewTests.swift`，3 個案例）：**
- 節流：模擬快速拖曳（10 個不同 exposure 值，落在合法範圍 `[-5, 5]` 內——踩過一次坑，超出範圍的值會被 clamp、導致 `history.setAdjustment` 回傳 false 沒觸發節流邏輯，浪費了一輪除錯）驗證只送出遠少於 10 次、最後一個值沒丟、間隔 ≥ 節流下限。
- 單一調整不會被節流拖慢。
- decode 失敗會清空 `previewImage`，不留殘影。
- 驗證方式：把 `EditorViewModel.swift` 的修法暫時 `git stash`，用舊版程式碼跑同一批測試，確認其中 2 個真的會失敗，再 `stash pop` 還原——避免寫出空測試。
- `Tests/LumaHarborAppTests/AppTestSupport.swift` 同時新增了 `RecordingPreviewRenderer`／`SelectivelyFailingPreviewRenderer` 兩個測試替身，並讓 `makeServices(...)` 多一個 `previewRenderer` 參數可以注入自訂 renderer。
- 全套件跑過：335 tests，0 failures，8 skipped（跟以前一樣是需要真實硬體的 `RawFixtureTests`）。build 也過。

**Gate E 第 9 項的前置準備做好了**：`Fixtures/Private/ReadOnly-Test/`（3 張 ARW 複製檔，目錄 `chmod 555`、檔案 `chmod 444`，已用 `touch` 驗證真的無法寫入，且在 `.gitignore` 排除範圍內不會誤 commit）。

**還沒做、下一步要人工在真機上走的清單：**
1. ~~**Gate E 第 7、8 項（拔插 SSD）**~~ — **2026-08-18 人工測完，通過，見下方新增段落。**
2. ~~**Gate E 第 9 項（唯讀資料夾）**~~ — **2026-08-18 人工測完，通過，見下方新增段落。**
3. **Gate E 第 10 項重測（損壞 RAW，驗證今天的修法）**：用 `Fixtures/Private/Corrupt-Test/` 點開 `_DSC1898-corrupt.ARW` → 應該要跳錯誤提示、**不再顯示前一張的殘影**；順便看「首次點 96 loading 不出來」是否還會重現。
4. ~~**損壞 sidecar 是否真的有隔離機制**~~ — **2026-08-18 讀 code 確認完畢，機制存在且完整，不需要再重測，見下方新增段落。**
5. **Gate F UI 矩陣**：十個調整項目即時預覽＋個別 Reset；原圖比較／Undo／Redo／整張 Reset；拉滑桿後立刻切照片＝先存檔，唯讀情境下切照片＝停留原照片；匯出 JPEG／流水號／取消清暫存／Finder 顯示；各種錯誤情境（offline／read-only／unsupported／corrupt／disk-full）都要有下一步提示。
6. **Gate F 效能量測**：Instruments 還沒接，順手用碼表確認節流修法後滑桿反應是不是真的接近 150ms 目標（不是完全靠肉眼猜）。

**跟這次 session 無關、但使用者已經決定的事（不要在驗收沒完成前先做）**：`docs/reference/next-phase-scope-notes.md` 記的下一階段範圍（風格檔雙軌、批次/多格式匯出）要等 MVP 簽收後才開新 spec，2026-08-16 已經明確決定順序。

## 2026-08-18（續）：損壞 sidecar 隔離機制讀 code 確認結果

**結論：機制本來就有做，而且做得完整；昨天測不出反應是測試素材選錯，不是功能缺失。不需要補程式碼修法。**

- `FileSidecarRepository.loadSidecar(for:)`（`Sources/PhotoLibraryCore/Sidecar/SidecarRepository.swift:171-215`）decode 失敗時會把壞檔搬到 `.lumaharbor/quarantine/<photoID>-<timestamp>.json`（原檔清空），並丟出 `SidecarError.corruptSidecar`。
- 這個錯誤會一路傳到 `LibraryViewModel.openSelectedPhoto` 系的邏輯（`Sources/LumaHarborApp/ViewModels/LibraryViewModel.swift:492-510`）：照片改用 `.neutral` 開啟（不卡住、不偽成功），同時設定 `alert = UserAlert(title: "Couldn't read saved edits", ...)`，由 `RootView.swift:27` 的 `.alert(item: $model.alert)` 顯示出來。
- 端到端已有測試覆蓋：repository 層 `Tests/PhotoLibraryCoreTests/SidecarRepositoryTests.swift`（含唯讀磁碟搬不動壞檔的情境）、ViewModel 層 `Tests/LumaHarborAppTests/LibraryViewModelTransitionTests.swift`（模擬 `loadAdjustments` 丟 `corruptSidecar`，驗證選取行為跟 alert）。

**為什麼昨天用 `BAD-SIDECAR-DEADBEEF.json` 測不出東西**：sidecar 檔名規則是 `<PhotoID 的 UUID>.json`（`PhotoID.sidecarFilename`，`Sources/PhotoLibraryCore/Model/PhotoID.swift:24`）。App 只會用「已知照片的 PhotoID」去開對應檔案；`storedSidecarIDs()`（重建索引用）也會用 `PhotoID(uuidString:)` 過濾掉非法 UUID 檔名。`"DEADBEEF"` 不是合法 UUID，這個檔案從頭到尾沒有任何程式碼路徑會碰它——是孤兒檔案，跟隔離機制有沒有做無關。

**如果之後要真人手動重驗這條路徑**：改壞某張照片*既有*的合法 sidecar（`.lumaharbor/edits/<那張照片的真實 UUID>.json`），而不是另外放一個隨意命名的檔案，才會踩到 `loadSidecar` 的 decode-失敗分支。

## 2026-08-18（續二）：人工重測 Gate E 第 10 項時發現新 bug——Inspector 面板顯示延遲一拍，已修

**發現方式**：使用者用 `Fixtures/Private/Corrupt-Test/` 實測 96→97→98→96→97，附五張截圖。98（壞檔）正確跳出 alert（P1 修法驗證通過），但 96／97 的 Adjustments 面板數值明顯不對：97 第一次顯示 Blacks=0（正確，97 本來沒存檔），96 第二次顯示 Blacks=0（應為存檔值 88.49，錯）、97 第二次顯示 Blacks≈88（應為 0，錯）。核對 `Fixtures/Private/Corrupt-Test/.lumaharbor/edits/C3BDC256-....json` 確認 88.49 是 96 的真實存檔值。

**根因**：`Sources/LumaHarborApp/ViewModels/LibraryViewModel.swift`（修前 `:52`）`let editor = EditorViewModel()` 不是 `@Published`，`init()`（修前 `:75`）沒有把 `EditorViewModel.objectWillChange` 轉發給 `LibraryViewModel.objectWillChange`。全專案只有 `LibraryViewModel` 被注入成 environmentObject（`LumaHarborMainApp.swift:15`、`RootView.swift:38`），`EditorView`／`InspectorView` 都是透過 `@EnvironmentObject var model: LibraryViewModel` 間接讀 `model.editor.*`——editor 自己內部狀態變化（開新照片、預覽跑完）不會觸發 SwiftUI 重繪，畫面只在 `LibraryViewModel` 自己的 `@Published`（例如 `selectedPhotoID`）變動時重繪一次，讀到的是上一張照片剛好在背景載入完、但從沒被畫出來的舊快照——**顯示延遲一拍，不是資料錯**（`save()`/自動存檔讀的是 `editor.history` 即時內部狀態，不是畫面快照，底層存檔應該沒事，但畫面不可信）。這也解釋了使用者問的「第一張是否要雙點擊才會打開」的觀感——不是真的沒反應，是重繪沒被觸發，看起來像卡住。

**修法**（已完成，working tree 未提交）：`LibraryViewModel.init()` 加一行 Combine 轉發：
```swift
editorForwarding = editor.objectWillChange.sink { [weak self] in
    self?.objectWillChange.send()
}
```
新增 `private var editorForwarding: AnyCancellable?` 存住訂閱、`import Combine`。

**回歸測試**：`Tests/LumaHarborAppTests/LibraryViewModelTransitionTests.swift` 新增 `testEditorOnlyChangesRepublishThroughTheLibraryViewModel`——開照片後訂閱 `model.objectWillChange`，呼叫只會動到 `editor` 自己 `@Published` 狀態的 `model.editor.setAdjustment(...)`，斷言 `model.objectWillChange` 有被觸發。用 `git stash` 只還原 `LibraryViewModel.swift` 跑過一次，確認這個測試在沒有修法時真的會失敗（`0 is not greater than 0`），修法回來後轉綠，避免空測試。

**全套件跑過**：336 tests，0 failures，8 skipped（一樣是需要真實硬體的 `RawFixtureTests`）。build 也過。

**人工重測結果（2026-08-18，同一台機器）**：使用者重新走過 96→97→98→96→97，確認「修好了」——面板數值即時正確反映每張照片。**Gate E 第 10 項（壞檔顯示偽成功）連同這個延遲一拍的顯示 bug，都算重測通過。**

**另外一條沒解的線索**：使用者截圖底部持續出現被裁切的 `Error Domain=NSCocoaErrorDomain ... code=4097`（旁邊有雲朵圖示），4097 是 NSXPCConnectionInterrupted。還沒拿到完整文字，不確定是不是 App 自己印的、跟 RAW 解碼是否有關，也不確定跟 96 第一次載入特別慢有沒有關係——下次人工測試時記得截一張這行文字完整不被裁切的畫面。使用者這輪重測沒有再提到這個訊息，暫時擱置，不影響任何簽收判斷。

## 2026-08-18（續三）：Gate E 第 9 項（唯讀資料夾）人工測完，通過

用 `Fixtures/Private/ReadOnly-Test/`：

- **加入資料夾**：立刻跳出「Scanned, but couldn't update the library file / 路徑唯讀 / 照片仍可瀏覽，需解鎖磁碟才能存回調整」——訊息清楚、有下一步。**通過。**
- **拉滑桿**：滑桿可正常互動（本地暫存調整還在），工具列出現橘色「Not saved」警告三角形圖示（`SaveStateLabel` 的 `.failed` 分支），不是偽成功。**通過。**
- **警告圖示的 tooltip**：`.help("This drive is read-only, so edits can't be saved.")` 確實有接上，但使用者反映「通知有點不太明顯很難出現」——原生 macOS tooltip 本身要滑鼠完全靜止停留一陣子才會跳出，這是系統行為特性，不是完全失效。**列為次要 UX 待改善項目（不擋簽收）**：目前唯一的失敗原因說明管道是這個容易被忽略的原生 tooltip，沒有更明顯的 UI（例如 popover 或第一次失敗時跳一次性 alert）。之後如果要處理，可以考慮把 `saveState == .failed` 的說明也接進 `editor.alert`（跟壞檔那條路徑一樣），但這次驗收先不擋。
- **匯出**：目的地由使用者自己在系統儲存面板選（`ExportSheet.swift` 的「Choose Destination…」），跟來源資料夾唯讀與否無關。使用者實測選了可寫入的目的地，成功匯出並顯示「Exported _DSC1896.jpg」+「Show in Finder」。**通過，且確認這條跟來源唯讀無關是預期設計，不是 bug。**

**Gate E 第 9 項整體結論：通過，但過程中發現並修掉一個真的卡死的 bug，見下方。**

## 2026-08-18（續四）：唯讀資料夾上編輯過一次就永久卡死無法切換，已修

**發現方式**：使用者在 `ReadOnly-Test` 拉了滑桿、跳出「Couldn't save your edits」警告後，點 OK、按 Adjustments 面板的「Reset All」把所有調整恢復到 0（=跟磁碟上完全一樣，因為這張照片本來就沒存過任何編輯），然後想切去別的資料夾/照片——**還是被同一個警告擋下來**，完全卡死，唯一出路是解鎖磁碟權限或砍掉 App 重開。

**根因**：`Sources/LumaHarborApp/ViewModels/EditorViewModel.swift` 的 `didChangeAdjustments()`（修前）不管三七二十一，只要有任何編輯事件（包含 `undo()`／`resetAdjustment()`／`resetAll()`）就把 `saveState` 設成 `.pending`——即使改完的值跟磁碟上存的一模一樣。而 `SaveState.isDirty` 把 `.pending`／`.saving`／`.failed` 全算 dirty，`flushPendingEdits()`（`LibraryViewModel.applyPendingSelections()` 唯一的切換前置檢查）只要 dirty 且唯讀就直接失敗並擋下這次切換、把 pending selection 整個丟掉，不會重試。所以一旦在唯讀照片上碰過一次滑桿，`saveState` 就再也回不去 `.unchanged`——就算 Reset All 把值改回跟磁碟一致，還是被判定「有東西沒存」，永遠卡住。

**修法**（已完成，working tree 未提交）：`EditorViewModel` 新增 `private var lastSavedAdjustments: PhotoAdjustments`（`open()` 時設成剛載入的值，`save()` 成功後同步更新）。`didChangeAdjustments()` 改成比較 `history.current == lastSavedAdjustments`：相等就直接判 `.unchanged`（連帶取消排隊中的自動存檔任務），不相等才維持原本 `.pending` + 排自動存檔的邏輯；預覽渲染（`requestInteractivePreview()`/`scheduleSettledPreview()`）維持無條件執行，不受這個判斷影響——滑桿位置不管乾不乾淨都要即時反映。

**回歸測試**：`Tests/LumaHarborAppTests/EditorViewModelPreviewTests.swift` 新增 `testResettingBackToTheSavedValueOnAReadOnlyDriveUnblocksNavigation`——唯讀開照片、改一個值（驗證仍會被擋，這條路徑要保留，不是全部放行）、`resetAll()` 回到跟磁碟一致的值、驗證 `saveState` 不再 dirty 且 `flushPendingEdits()` 回傳 true。一樣用 `git stash` 只還原 `EditorViewModel.swift` 跑過，確認沒有修法時這個測試真的會失敗（兩個斷言都紅），修法回來後轉綠。

**全套件跑過**：337 tests，0 failures，8 skipped。build 也過。

**人工重測結果（2026-08-18）**：使用者重新走過「拉滑桿→Reset All→切換照片/資料夾」，確認「好了」，不再卡死。也確認了「不 Reset、直接想放棄編輯切走」目前仍會被擋——這是刻意保留的行為，使用者接受現狀，先不加「放棄編輯並離開」按鈕。**這個 bug 連同 Gate E 第 9 項都算重測通過。**

## 2026-08-18（續五）：Gate E 第 7、8 項（拔插 exFAT SSD）人工測完，通過

用 `/Volumes/Untitled/LumaHarbor-exFAT-Test`（11 張），照片開著、有一個未存檔的調整（Temperature +31）時直接拔隨身碟：

- **拔掉當下**：App 沒有 crash；縮圖跟已快取的預覽圖都還在畫面上；未存檔的 Temperature +31 調整值原樣保留（沒有被清空或 reset）；側邊欄該資料夾正確顯示「Offline」，底部出現清楚的「Offline — reconnect the drive to edit or export」+「Reconnect…」按鈕；工具列同時顯示警告圖示。**通過。**
- **重插回去**：側邊欄自動變回正常（不再顯示 Offline，照片數量正常顯示回 11 photos），底部變成「Ready」；不需要使用者手動介入。**通過。**
- **未存檔的調整補存**：使用者確認重插回去後工具列狀態最終自動變成「Saved」——離線期間失敗的自動存檔在偵測到磁碟恢復可寫後有自動重試並成功寫回 sidecar，不需要手動存檔。**通過。**

**Gate E 第 7、8 項整體結論：通過，沒有發現新 bug。**

## 2026-08-18（續六）：Gate F 開始，Undo/Redo 快捷鍵完全沒反應，已試修

**發現方式**：開始走 Gate F UI 矩陣，測 Undo/Redo。使用者連按 ⌘Z 完全沒反應，「一直停留在這裡」。排查順序：
1. 打開選單看「Undo」項目——**正常黑色可以點選，不是灰掉**（代表 `canUndo` 狀態本身是對的，不是狀態過期）。
2. 直接滑鼠點選單裡的「Undo」——**成功退回一步**（代表按鈕背後的邏輯完全沒問題）。
3. 先點畫面中間的照片本身讓焦點離開滑桿，再按 ⌘Z——**還是沒反應**（排除「滑桿控制項搶走鍵盤焦點」這個猜測）。

**結論**：選單項目跟背後邏輯都是對的，純粹是**實體按鍵傳不到選單快捷鍵系統**。這是 SwiftUI 在 macOS 上 `CommandGroup(replacing: .undoRedo)` 一個有名的已知缺陷——沒有真正的 `NSResponder` 實作 `undo:`/`redo:` 時，自訂的 `.undoRedo` key equivalent 不保證會被正確路由，即使選單項目本身狀態正確、點擊也正常。

**修法**（已完成，working tree 未提交，`Sources/LumaHarborApp/LumaHarborMainApp.swift`）：加裝一個 `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` 的 local key-down monitor（AppKit 在一般選單 key-equivalent 派送之前就會先問過這個 monitor），直接攔截 ⌘Z／⌘⇧Z，判斷 `canUndo`/`canRedo` 後直接呼叫 `model.editor.undo()`/`redo()`，攔截到就回傳 `nil`（吃掉事件不再往下傳），沒攔截到（例如純打字元 "z"，或當下不能 undo/redo）就把原始 `event` 原封不動傳回去，不影響其他按鍵行為。原本 `LumaHarborCommands.swift` 的選單項目／`.keyboardShortcut` 保留不動，繼續當作選單可點擊的入口，跟這個 monitor 是互補、不衝突（monitor 攔到就消耗掉事件，選單快捷鍵永遠不會真的被觸發，兩邊不會重複執行 undo）。

**這是 UI 事件層級的修法，沒辦法寫自動化 XCTest 驗證**（需要真的送 NSEvent 到視窗），只能靠人工在真機上按 ⌘Z／⌘⇧Z 驗證。build 跟現有 337 tests 都過，沒有引入警告或迴歸。

**人工重測結果（2026-08-18，第一次修法）**：⌘Z 仍然沒有反應，跟修法前一樣。

**第二次嘗試**：懷疑選單本身的 `.keyboardShortcut("z", ...)` 在 `performKeyEquivalent:` 那層就把 ⌘Z 這個組合鍵「認領」掉了（即使選單項目本身可點擊、狀態正確），導致連新加的 local monitor 都收不到這個按鍵事件。把 `LumaHarborCommands.swift` 的 Undo/Redo 按鈕上的 `.keyboardShortcut` 整個拿掉，改成完全依賴 monitor 處理實體按鍵，選單維持只能滑鼠點選（不會再顯示 ⌘Z 提示，純視覺差異）。build／337 tests 都過。

**人工重測結果（2026-08-18，第二次修法）**：⌘Z 還是沒有反應，使用者回報「一直有錯誤」（原因還不確定）。

**決定**：兩次嘗試都沒修好，使用者決定**先擱置這個問題，不擋 Gate F 其他項目的驗收**。目前狀態：
- Undo/Redo **透過滑鼠點選單完全正常**（功能本身沒問題，只是快捷鍵這條路徑有問題）
- ⌘Z／⌘⇧Z 快捷鍵**目前仍然無效**，兩次修法都沒解決，根因還沒完全找到（「一直有錯誤」的錯誤內容還沒問使用者是什麼錯誤、在哪裡跳出來——下次要接續這個問題時，第一步應該先問清楚具體錯誤訊息，而不是繼續憑空猜測 SwiftUI Commands 的行為）
- **列為已知問題（不擋 MVP 簽收，因為有滑鼠點選這個可用替代路徑），之後要再深入排查時的建議切入點**：直接用 Instruments 的 Keyboard/Events 追蹤，或在 local monitor 內先加一個最簡單、不判斷任何條件、逢鍵必印的 log（例如收到任何 keyDown 就寫一行到檔案）來確認 monitor 到底有沒有被呼叫到，而不是先假設是哪一層的問題。

## 2026-08-19：Gate F 原圖比較（Original 按鈕）點擊無法取消釘住，已修

**發現方式**：走 Gate F「按住／點擊 Original 比較鍵」這段，使用者回報「點擊後有還原但不會變成已編輯」——點一下 Original 會顯示原圖沒錯，但不管再點幾次都回不去已編輯畫面，永遠卡在原圖。

**根因**：`Sources/LumaHarborApp/Views/EditorView.swift`（修前）的 `CompareButton` 同時掛了 `Button` 本身的 tap 動作（`model.editor.isShowingOriginal.toggle()`）跟一個 `simultaneousGesture(DragGesture(minimumDistance: 0))`（原本設計是拿來做「按住預覽」）。`minimumDistance: 0` 代表**單純點一下也會完整觸發這個 DragGesture 的 onChanged→onEnded**，不是只有真的拖曳才會觸發。所以每次點擊，實際上是兩套機制同時作用在同一個 `isShowingOriginal`：DragGesture 的 onEnded 先把它設回 `false`，Button 的 `.toggle()` 接著把它從 `false` 翻回 `true`——不管點幾次，最終永遠停在 `true`（顯示原圖），無法翻回已編輯畫面。這跟今天稍早的 Undo/Redo 快捷鍵問題是同一類「兩套機制搶同一個狀態」的 bug，但根因跟解法完全不同（那個到目前還沒解掉）。

**修法**（已完成，working tree 未提交）：把「進入 peek 模式」延後到超過 250ms 的按住門檻才觸發（用一個可取消的 `Task` + `Task.sleep`）。這樣一次快速點擊（放開發生在 250ms 內）從頭到尾都不會碰到 `isShowingOriginal`——`peekTask` 在 `onEnded` 就被取消掉，`isHolding` 從未被設成 `true`，DragGesture 這邊完全是無操作，`isShowingOriginal` 只剩下 Button 自己的 `.toggle()` 在動，行為就恢復成正常的兩態切換。真的按住超過 250ms 才會進入原本的「臨時顯示原圖，放開恢復」邏輯。

**這是手勢層級的修法，沒辦法寫自動化 XCTest 驗證**，只能人工在真機上點擊/按住測試。build 跟現有 337 tests 都過，沒有新增警告或迴歸。

**人工重測結果（2026-08-19，第一次修法）**：使用者回報「都不行」——點擊沒有正常切換兩態，**連原本就能動的「按住預覽」也一起壞掉**（迴歸）。

**根因（第一次修法為什麼連按住都壞了）**：第一版用 `Task { try? await Task.sleep(...) }` 延遲 250ms 才進入 peek 模式。但使用者按住的當下，AppKit 會把主執行緒的 RunLoop 切到 `.eventTracking` 這個特殊 mode 來處理即時拖曳互動，這個 mode 底下一般的計時器／Task 排程可能會被餓死、完全不會觸發，直到放開滑鼠、RunLoop 離開 tracking mode 才會補跑——但那時候 `onEnded` 早就跑完、把 `peekTask` 取消掉了，等於整個 gesture 對 `isShowingOriginal` 完全沒有作用，畫面只剩下（同樣壞掉的）Button toggle 在動，點擊跟按住兩種操作都失效。

**第二次修法（已完成，working tree 未提交）**：整個改寫成**純同步**版本，完全不用 `Task`／`async`，用真實的 `Date()` 時間戳記在 `onChanged`／`onEnded` 這兩個一定會被呼叫到的 callback 裡直接算按壓時長，避免任何跟 RunLoop tracking mode 有關的計時器餓死風險：
- 新增 `isPinned`（持久釘住狀態，跟臨時的 `isShowingOriginal` 分開）跟 `pressBeganAt`（按下時間戳記，同步寫入）。
- `Button` 本身的 action 改成空的（刻意），完全由手勢決定，不再有兩套機制搶同一個狀態。
- `onChanged`：按下當下立刻 `isShowingOriginal = true`（不管是點擊還是按住，先給即時視覺回饋）。
- `onEnded`：算出這次按壓時長，**低於 250ms（點擊）**→ 翻轉 `isPinned` 並同步 `isShowingOriginal`；**大於等於 250ms（按住）**→ 放開後回到 `isPinned` 當下的值（沒釘住就變回已編輯，已釘住就繼續顯示原圖）。

build／337 tests 都過。**這也是手勢層級修法，沒辦法寫自動化測試**——已用完這個環境目前能做的手段（讀 code、build、跑 test），沒有 UI 自動化權限（見下方「2026-08-19 自主工作總結」），需要人工在真機上驗證點擊兩態切換、按住預覽兩種操作是否都恢復正常，這是**明天早上優先要看的項目**。

## 2026-08-19 自主工作總結（使用者今晚離線，交代「自己做驗測跟開發，明天早上檢查」）

**環境限制先說清楚**：這個 Bash 環境沒有「輔助使用」（Accessibility）跟「螢幕錄製」權限——`osascript`／System Events 呼叫回傳 `-1719`（不允許輔助取用），`screencapture` 回傳「could not create image from display」。也就是說**沒辦法自己點擊畫面或截圖驗證 UI 行為**，只能做到：讀 code、`swift build`、`swift test`、寫回歸測試、對照既有測試覆蓋範圍做推理驗證。以下是在這個限制下做的事，明天早上請優先人工驗證「還沒做」欄位列出的項目。

**這次自主工作階段做的事**：
1. Original 比較鍵的第二次修法（見上方），已 build/test 過，但兩種操作都還沒人工驗證。
2. 主動掃過 `Sources/LumaHarborApp/Views` 有沒有其他地方用了跟 Original 按鈕同類型的 `simultaneousGesture`／雙機制搶狀態寫法——**只有 `EditorView.swift` 這一處，沒有發現第二個類似的潛在 bug**。
3. 對照 Gate F 人工功能矩陣（`docs/superpowers/specs/2026-08-15-mac-first-mvp-acceptance-plan.md` §Gate F）逐項核對現有自動化測試覆蓋範圍：
   - **「滑桿後立即切換照片時，edit 先保存；保存失敗時停留原照片」**——已有專門的單元測試直接覆蓋這條路徑：`Tests/LumaHarborAppTests/LibraryViewModelTransitionTests.swift` 的 `testDirtyEditIsWrittenBeforeTheNextPhotoOpens`（驗證切照片前 sidecar 真的寫入正確的值）跟 `testASaveFailureKeepsTheSelectionAndTheDirtyState`（模擬存檔失敗，驗證選取沒有移動、還停在原照片、alert 有 nextStep）。**這條在自動化測試層級已經有堅實證據，不是只有結構推理**。
   - **「單張 JPEG 匯出、同名流水號、取消清除暫存檔」**——`Tests/RawProcessingCoreTests/JPEGExportTests.swift` 已有 `testASecondExportGetsASerialSuffixRatherThanOverwriting`、`testCancellingAnExportStopsItAndRemovesThePartialOutput`、`testCancellationActuallyInterruptsTheDecode`、`testCancellingDuringTheMetadataReadStillLosesTheRename` 四個測試，直接覆蓋流水號跟取消清理兩條路徑，而且連「取消發生在渲染中／metadata 讀取中」這種時序競態都有測到。讀了 `JPEGExporter.swift` 的實作：一律先寫到隱藏的 `.tmp` sibling 檔、只有最後一步才 rename，任何錯誤／取消都會 `try? fileManager.removeItem(at: temporaryURL)` 清掉暫存檔——設計本身就是「絕不留下看起來像完成的半成品」。**「Finder 顯示」（`revealExportInFinder` 呼叫 `NSWorkspace.shared.activateFileViewerSelecting`）沒辦法寫單元測試，這行程式碼本身邏輯很單純（guard 有路徑才呼叫），風險低，但仍待人工按一次確認真的會開 Finder 並選中檔案。**
   - **「offline、read-only、corrupt 都有下一步」**——這三項今天已經人工測過，通過。
   - **「unsupported、disk-full 都有下一步」**——**還沒人工測過**。讀 code 確認 `RawDecodingError.unsupportedFormat`（`Sources/RawProcessingCore/Decoding/RawDecodingError.swift:24-41`）跟 `AtomicWriteError.insufficientDiskSpace`（`Sources/PhotoLibraryCore/Sidecar/AtomicFileWriter.swift:17-31`）都有定義清楚的 `errorDescription` 跟 `recoverySuggestion`（next step），而且跟今天已經人工驗證過（corrupt sidecar、read-only）的錯誤走同一條 `UserAlert(title:error:)` 管道——架構上一致，理論上應該一樣能正確顯示，但**這兩種情境本身還沒人工重現過**（unsupported 需要一個真的不支援的檔案格式；disk-full 需要真的塞滿一個小磁碟分割區或 disk image，這兩者都需要人工準備測試素材，我無法自己生成）。
   - **Gate F 效能量測（Instruments）**——完全需要人工搭配 Instruments.app 操作，這次沒有進展。

**明天早上請優先做的事（照優先順序）**：
1. **人工驗證 Original 比較鍵第二次修法**：點擊兩態切換、按住預覽，兩種操作都要測。
2. **人工驗證「Show in Finder」**：匯出一張照片後點這個按鈕，確認 Finder 開啟並選中檔案。
3. **視需要準備 unsupported／disk-full 測試素材**：例如找一個 `.CR2`／`.NEF` 之類非 Sony ARW 的 RAW 檔測 unsupported；用 disk image 開一個很小的磁碟分割區測 disk-full。這兩項如果覺得優先度不高，也可以先跳過，不是 blocker（原因見上：架構上跟已驗證過的其他錯誤情境一致）。
4. **Undo/Redo 快捷鍵**：仍是已知未解問題（滑鼠點選單正常），下次要排查時先問清楚使用者說的「一直有錯誤」具體是什麼錯誤、在哪裡看到的，不要再憑空猜測 SwiftUI Commands 行為。
5. **Gate F 效能量測**：Instruments 還沒開始，全部待補。

## 2026-08-19（續）：人工驗證「Show in Finder」，通過

匯出一張照片後點「Show in Finder」，Finder 開啟並選中剛匯出的檔案。**通過。**

## 2026-08-19（續二）：人工驗證 Original 比較鍵第二次修法，通過

快速點擊兩態切換、按住預覽放開恢復，兩種操作都正常。**通過。**此前兩次踩雷（第一次 `Task.sleep` 在 `.eventTracking` RunLoop mode 下被餓死、第二次改純同步版本）到這裡確認修好，不再是待驗證項目。

**Gate F 待辦清單（原五項）目前狀態**：
1. ~~Original 比較鍵~~ — 通過
2. ~~Show in Finder~~ — 通過
3. unsupported／disk-full 測試素材 — 非阻塞，視需要再做
4. Undo/Redo 快捷鍵 — 使用者確認「快捷鍵不好驗測」，決定不繼續深究「一直有錯誤」的具體內容；維持已知問題狀態，**滑鼠點選單是唯一目前確認可用的路徑，快捷鍵維持無效**，不擋簽收
5. Gate F 效能量測（Instruments）— 未開始

## 2026-08-19（續五）：中文化補完（調整名稱、錯誤訊息、系統面板），另外發現一個需要人工驗證的疑點

派 agent 補完所有還沒接上 `Localizable.strings` 的使用者可見字串——最主要的缺口是 `InspectorView` 的十個調整滑桿名稱（Exposure/Contrast/…）跟三個分類標題（White Balance/Tone/Color），這些走的是 `Text(String)`（逐字顯示，不查表），不管 `.strings` 裡有沒有對應 key 都不會被翻譯，是目前為止最明顯但沒人發現的中文化漏洞。同時補了 `NSOpenPanel` 的 9 個標題/訊息/按鈕字串（直接指派 `panel.title` 也不會走 SwiftUI 自動查表），以及所有 `LocalizedError` 的 `errorDescription`/`recoverySuggestion`。`.strings` 兩份各從 55 個 key 增加到 169 個（新增 114，key 數兩邊一致，`plutil -lint` 過）。build／337 tests 都過。

**主 session 審查時額外修正**：agent 交回來的版本裡，掃描進度那句「N photos, M skipped」直譯後在中文讀起來語意不完整（`"12 張", "3 略過"`——缺名詞），已改成 `"found"` = 「張照片」、`"skipped"` = 「張跳過」，讓「掃描中── 12 張照片」「12 張照片, 3 張跳過」這種組合句讀起來是完整的中文句子，不是逐字拼接。

**主 session 審查時發現的疑點（尚未解決，需要人工用真機驗證）**：用 `-AppleLanguages '(zh-Hant-TW)'` 這個標準的 Apple 語言測試參數（Xcode 的「App Language」launch argument 背後也是用這個）直接啟動編譯出來的 `LumaHarbor` binary，實測 `Bundle.main.preferredLocalizations` 跟 `Bundle.module.preferredLocalizations` 都回傳 `["en"]`，即使 `Locale.preferredLanguages` 已經正確顯示 `["zh-Hant-TW"]`，且已經排除大小寫問題（`Sources/.../Resources/zh-Hant.lproj` 被 SwiftPM 的 `.process()` 資源規則轉成 `zh-hant.lproj` 全小寫是既有已知行為，2026-08-16 那次就已經在 `Tests/LumaHarborAppTests/LocalizationSmokeTest.swift` 裡繞開處理過，這次連刻意改用 `.copy()` 保留原始大小寫 `zh-Hant.lproj` 都測不出差異）。換句話說：**用命令列參數強制語言，`Bundle` 的語言協商機制完全沒反應，一直卡在英文**。

這跟現有的 `LocalizationSmokeTest.swift` 不衝突——那個測試是直接用路徑指到特定 `.lproj` 子目錄讀值（繞過系統語言協商），驗證的是「翻譯檔案內容本身正確」，不是「系統語言切換後真的會顯示中文」。我這次測的是後者，用的是命令列模擬，不是真的改 macOS 系統設定，測試方法本身也可能不夠準確（例如純 command-line 執行的 binary 跟透過 Finder/LaunchServices 啟動的 `.app` 在 bundle 語言協商上可能行為不同，這點我没有進一步驗證的工具，這台環境沒有輔助使用/螢幕錄製權限，沒辦法真的切系統語言後開 App 用眼睛看）。

**建議**：下次人工驗收時，麻煩實際去「系統設定 → 一般 → 語言與地區」把偏好語言切成繁體中文（或至少確認目前就是），然後 `swift run LumaHarbor` 打開 App 看調整面板名稱、Undo/Redo 選單這些**這次新加的**中文有沒有真的出現。如果沒有，代表這是一個獨立於本次字串補完之外、範圍更大的既有 bug（可能連 2026-08-16 那批最早的中文化都沒有真的在 `swift run` 環境下顯示過），需要另開 spec 處理，不是能立刻在這個環境憑空修好的事。
