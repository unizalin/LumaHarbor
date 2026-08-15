# LumaHarbor Mac-first MVP 驗收與收尾計畫

- 狀態：已核准，待 Claude 執行 Gate C 第一工作包
- 日期：2026-08-15
- 基準分支：`main`
- 基準 commit：`3a5f6798cfdd51fd6a814e43414ea261c60f23ea`
- 上位規格：`2026-08-13-mac-first-mvp-design.md`

## 1. 目的

目前主要功能與 lossless bounded scan pipeline 已完成 source-level review，但 Mac-first MVP 尚不能宣告完成。本階段的目標不是新增產品功能，而是用完整 Xcode、Apple Silicon、Sony `.ARW` 與外接儲存裝置，逐項關閉主規格 §13 的十個驗收條件。

完成時必須能回答三件事：

1. 所有自動化測試是否真的在完整 XCTest runtime 執行並通過，而不是只有 parse、typecheck 或 smoke。
2. Sony `.ARW` 的解碼、預覽、調整與完整尺寸 JPEG 匯出是否在 Apple Silicon／Metal 路徑正確。
3. APFS、exFAT、bookmark、離線／重接與唯讀情境是否在真實 App lifecycle 中不遺失資料。

## 2. 已知基準與限制

### 2.1 已通過

- `swift build -Xswiftc -strict-concurrency=complete`
- bounded pipeline 8 組 runtime smoke，含 10,000 筆 lossless／high-water `<= 2`
- 四個 test target strict-concurrency typecheck
- 全部測試原始碼 parse
- production 掃描路徑無 unbounded `AsyncStream`
- 共 316 個 `test*` 方法已存在；其中 `RawFixtureTests` 有 8 個真實 RAW 驗收案例

### 2.2 目前環境不能完成的事

目前開發主機實測為：

- `x86_64`
- `xcode-select -p` 指向 `/Library/Developer/CommandLineTools`
- `/Applications/Xcode.app` 不存在
- 未掛載 APFS／exFAT 測試 SSD

因此此機器不能提供 Apple Silicon、完整 XCTest、Metal/CIRAWFilter 或外接 SSD 的最終驗收證據。

### 2.3 已知測試缺口

- `FileBookmarkStore` 沒有獨立 unit tests；現有 bookmark／重啟恢復主要由 `LibraryLifecycleTests` 間接覆蓋，而且 host 無法建立 security-scoped bookmark 時會 skip。
- `startAccessingSecurityScopedResource()`／`stopAccessingSecurityScopedResource()` 的真實配對、stale bookmark 更新、App 重啟後恢復，仍須 sandboxed App／實機驗收。
- 主規格 §11 的 300 ms thumbnail、150 ms preview、快速切換 100 次與記憶體不線性成長，尚無 Apple Silicon Instruments 報告。

## 3. 安全與資料邊界

- 不直接使用或改寫使用者唯一一份相片；先複製 fixture 到專用測試目錄。
- 不格式化、不抹除、不重新分割任何磁碟。APFS／exFAT 測試只操作使用者指定的專用資料夾。
- 私人 Sony `.ARW` 不加入 Git、不上傳 CI、不寫進 log 的完整本機路徑。
- 測試前後記錄 RAW 的檔案大小、內容 fingerprint 與 modification date；任一變動即為 P0 data-corruption blocker。
- 自動化不可代替拔除／重接 SSD、資料夾選擇器、視覺品質與 Finder 匯出檔確認。

## 4. 執行順序

### Gate A：驗收機與素材就緒

必要條件：

1. Apple Silicon Mac，macOS 14 或更新。
2. 完整 Xcode，且 `xcode-select -p` 指向 Xcode Developer 目錄。
3. 至少兩張可由該 macOS 解碼的 Sony `.ARW`：一張橫向、一張直向；建議再加入高 ISO 與高光／陰影明顯的樣本。
4. 一個 APFS 測試目錄與一個 exFAT 測試目錄；兩者都只放 fixture 副本。
5. 保留至少一個可安全製造唯讀情境的測試目錄或唯讀 disk image。

Preflight 必須記錄：

```sh
uname -m
sw_vers
xcodebuild -version
xcode-select -p
swift --version
```

通過條件：`uname -m` 為 `arm64`、Xcode 可用、fixture 目錄含 `.ARW`、兩種檔案系統的專用目錄可識別。任何一項不成立就停止，不進入後續 gate。

### Gate B：完整 XCTest baseline

先在未修改 production code 的基準 commit 執行：

```sh
swift test -Xswiftc -strict-concurrency=complete
```

要求：

- 四個 test target 全部 compile、link、execute。
- 記錄 executed／passed／failed／skipped 數量與完整失敗名稱。
- bookmark 相關 skip、read-only skip 與 RAW fixture skip 必須分開列出；skip 不得當成通過。
- 先保存原始 log，再開始修正，避免失去 baseline 證據。

通過條件：非環境限定測試 0 failure；任何 crash、hang、data race、double-resume 或 sanitizer 訊息都視為 blocker。

### Gate C：Claude 第一工作包—驗收工具與測試缺口

Claude 只處理下列範圍，不改產品功能：

1. 新增 `FileBookmarkStore` unit tests：save/load round-trip、排序、單一損壞檔隔離、remove、idempotence、未知檔案忽略。
2. 建立一個 repo 內 acceptance runner，負責 preflight、完整 XCTest、`RawFixtureTests`、strict-concurrency build 與結果摘要；不得自行安裝 Xcode、掛載或修改磁碟。
3. 新增驗收報告模板，記錄硬體、OS、Xcode、fixture 代號／hash、filesystem、測試數、skip、效能與人工結果。
4. runner 必須在缺 fixture、非 `arm64`、缺 Xcode 或缺測試目錄時 fail closed，明確說明缺哪一項。

除非測試需要且 spec 先補充，Claude 不得為了方便測試而改公開 API、bookmark 格式、sidecar schema、掃描語意或 UI 流程。

Codex review gate：檢查 runner 不會洩漏私人路徑、不會對磁碟做 destructive operation、測試不是只 parse/typecheck，並在可用環境重跑後才 commit。

### Gate D：Sony ARW／Metal／匯出

使用 repo 外 fixture：

```sh
LUMAHARBOR_RAW_FIXTURE_DIR=/path/to/private/fixtures \
  swift test --filter RawFixtureTests
```

8 個既有案例不得 skip，並確認：

- 每個 fixture 可由 `CIRAWFilter` 解碼。
- EXIF 尺寸、SONY make/model 與拍攝時間合理。
- 1024 px preview 不意外使用完整解析度。
- full decode 尺寸等於 RAW native size。
- white balance 調整確實改變輸出。
- JPEG 尺寸正確且標記 sRGB。
- 匯出前後 RAW fingerprint 與 modification date 完全一致。
- real-RAW preview scheduler 交付有效畫面。

人工補驗：方向、曝光、色偏、banding、黑白點與高光／陰影調整不能有明顯錯誤。

### Gate E：APFS／exFAT 與 bookmark lifecycle

兩種 filesystem 各完整執行一次：

1. 由系統面板加入專用測試資料夾。
2. 增量掃描、縮圖逐步出現，不等待全部掃完。
3. 編輯一張照片並確認 `.lumaharbor` sidecar 落地。
4. 關閉 App、重新啟動，確認 bookmark 恢復、selection／edit 可重新載入。
5. 刪除本機 SQLite 與 cache 後重建，PhotoID 與 edits 不變。
6. 將資料夾改名後走 relink，不能猜路徑或另建 identity。
7. App 開啟時拔除 SSD：保留 cached thumbnail，不 crash；未保存 edit 留在記憶體並可在重接後 retry。
8. 重接 SSD 並重新授權，既有 library identity 與 sidecar edit 保留。
9. 唯讀情境允許瀏覽，但保存與匯出顯示 actionable error，不能顯示偽成功。
10. 加入損壞 RAW 與損壞 sidecar：單檔失敗、掃描繼續、sidecar 被隔離而非覆寫。

通過條件：APFS 與 exFAT 的十項都留有結果；任何 crash、原檔變動、PhotoID 漂移、edit 遺失或偽成功都是 blocker。

### Gate F：UI 與效能

人工功能矩陣：

- 十個調整項目都能即時預覽與各自重設。
- 原圖比較、Undo、Redo、整張重設正確。
- 滑桿後立即切換照片時，edit 先保存；保存失敗時停留原照片。
- 單張 JPEG 匯出、同名流水號、取消清除暫存檔、Finder 顯示正確。
- offline、read-only、unsupported、corrupt、disk-full 類錯誤都有下一步。

Apple Silicon + Instruments：

- cached thumbnail 目標 `<= 300 ms`。
- slider preview 目標 `<= 150 ms`；超時時先有互動品質畫面。
- 快速切換照片 100 次後，in-flight work 與記憶體不持續線性成長。
- 大資料夾掃描 high-water 維持 bounded，UI main thread 不執行 RAW decode、hash 或 JPEG export。

效能未達目標可列 P1，但若 UI 無回應、記憶體持續線性成長或工作不能取消，升級為 blocker。

### Gate G：修正、回歸與最終簽核

每個實際失敗各自建立小型工作包：

1. 保存完整重現步驟、環境與 log。
2. Claude 實作最小修正與 regression test，不混入其他功能。
3. Codex 做 source review，重跑受影響 target、完整 suite 與對應實機案例。
4. 一個修正一個可回溯 commit；P0／P1 未清空前不得標記 MVP 完成。

最終通過需要：

- 主規格 §13 十項全部有自動或人工證據。
- 完整 XCTest 0 failure；環境限定 skip 都已有對應實機結果。
- Sony `.ARW`、APFS、exFAT、bookmark、Metal/CIRAWFilter、JPEG sRGB 全部通過。
- 無已知 data-corruption blocker。
- 驗收報告列出仍接受的 P2／限制，且不把 MVP 後功能混入本階段。

## 5. 分工

### Claude

- 依明確工作包實作 runner、測試缺口或具體 regression fix。
- 不 commit／push；接近用量上限時先更新 `/Users/u/AI-Shared/HANDOFF.md`。
- 不因環境失敗改動產品語意，也不把 skip 宣稱為 pass。

### Codex

- 維護 spec、baseline 與驗收矩陣。
- review Claude diff，獨立重現與驗證 blocker。
- 通過後負責 commit／push，並更新 HANDOFF。

### 使用者／實機操作者

- 指定可安全使用的 APFS／exFAT 測試目錄與私人 Sony `.ARW` fixture。
- 執行或允許資料夾選擇、App 重啟、SSD 拔除／重接與視覺品質判斷。
- 確認測試目錄內資料可被寫入／隔離；原始照片不進入自動化修改範圍。

## 6. 下一個可執行動作

1. 先準備符合 Gate A 的 Apple Silicon + Xcode 驗收機、Sony `.ARW` fixtures、APFS 與 exFAT 專用測試目錄。
2. 在基準 commit `3a5f679` 跑 Gate B，保存完整 baseline。
3. 同時可讓 Claude 實作 Gate C，但不得碰 production behavior；Codex review 後再合併。
4. Gate B/C 都通過後依序做 D、E、F；只針對實際失敗建立修正工作包。
