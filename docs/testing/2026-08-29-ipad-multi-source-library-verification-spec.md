# iPad 多來源 RAW 圖庫剩餘驗測規格

> **執行者注意：**本文件只關閉驗測與簽核，不新增產品功能。若任何 gate 發現產品缺陷，先在驗收報告記錄可重現步驟與證據，再以獨立修正 commit 處理並重跑受影響 gate。

**目標：**在真實 RAW、APFS、exFAT、Files provider 與 M1 以上 iPad 上，證明 iPad 多來源圖庫符合設計規格，且不修改 Sony `.ARW` 原檔。

**驗測架構：**先固定 commit 與環境，執行完整自動驗收；自動 gate 全綠後，再於真實 iPad 執行五組人工情境。最後做 spec 對照與獨立 pre-landing review，所有證據寫回既有驗收報告。

**技術環境：**Swift 6、SwiftPM、Xcode 26.6、iOS 17 以上、Apple Silicon Mac、M1 以上 iPad、APFS／exFAT 外接儲存裝置、Sony `.ARW` fixture。

## 1. 目前基線

| 項目 | 狀態 | 證據／說明 |
|---|---|---|
| 功能 Task 1–8 | 完成且已審查 | branch `codex/ipad-multi-source-library-durability` |
| Task 9 acceptance runner | 完成 | `Scripts/run-ipad-library-acceptance.zsh` |
| Library runner self-test | PASS | 單次與連續 10 次皆 exit 0 |
| Vertical-slice runner self-test | PASS | 完整 `__selftest` 通過且無殘留程序 |
| strict-concurrency build | PASS | 最近 production runner 證據 |
| 完整 `swift test` | PASS | 1,090 executed、0 skipped、0 failures |
| iPad Simulator build | PASS | 最近 production runner 證據 |
| bounded multi-source tests | PASS | 6 executed、0 skipped、0 failures |
| RAW fixture | 可用 | 私人路徑不得寫入報告或 commit |
| APFS fixture | 可用 | 私人路徑不得寫入報告或 commit |
| exFAT fixture | **未掛載** | 目前阻擋完整自動驗收 |
| M1+ iPad 五項實機 gate | **NOT RUN** | 阻擋最終簽核 |
| Final Review Gate | **NOT RUN** | 自動與實機 gate 後執行 |
| 初步靜態掃描 | **READY FOR V4** | `LumaHarborPadApp.swift` 的 fallback `try!` 已改為可呈現的啟動失敗狀態；仍需 V4 全範圍掃描確認無新命中 |

結論：產品功能開發已到 Task 8；Task 9 的工具與自測已完成。目前剩餘工作是完整 fixture 驗收、實機驗收，以及最後一輪 spec／程式碼審查。

## 2. 全域通過規則

1. `PASS` 只代表實際執行且所有檢查成功；`SKIPPED`、`NOT RUN`、缺少證據或無法判讀一律不能當成 `PASS`。
2. 任一自動步驟 exit code 非 0、測試執行數為 0、skip 非 0、failure 非 0、privacy scan 非 PASS，整體結果均為 FAIL。
3. 任一實機案例發生 crash、資料遺失、來源身份誤接、索引錯亂、編輯遺失、RAW checksum 改變或偽成功，立即停止後續簽核。
4. 驗收報告不得包含使用者家目錄、外接磁碟掛載點、fixture 私人絕對路徑、Apple Development Team ID 或其他帳號資料。
5. 不猜測或提交 Development Team；首次部署由使用者在 Xcode 選取自己的 team。
6. 所有修正必須使用獨立 commit，修正後重跑受影響的 focused tests、完整 `swift test`、strict-concurrency build 與本文件要求的相關 gate。
7. 任一必要實機項目仍是 `NOT RUN` 時，不得合併或宣稱本功能完成。

## 3. Gate V0：環境與素材就緒

### V0.1 固定驗收基準

先進入 `codex/ipad-multi-source-library-durability` branch 的 worktree 根目錄，再執行：

```bash
git status --short --branch
git rev-parse HEAD
uname -m
xcodebuild -version
xcode-select -p
```

通過條件：

- branch 為 `codex/ipad-multi-source-library-durability`；
- worktree 乾淨；
- `uname -m` 為 `arm64`；
- Xcode 與 command line tools 可用；
- 報告記錄完整 40 字元 commit，但不含私人路徑。

### V0.2 確認三個 fixture

操作者先在目前 shell 將三個實際目錄匯出為 `LUMAHARBOR_RAW_FIXTURE_DIR`、`LUMAHARBOR_APFS_TEST_DIR`、`LUMAHARBOR_EXFAT_TEST_DIR`；值不得寫入 tracked 文件。接著執行：

```bash
: "${LUMAHARBOR_RAW_FIXTURE_DIR:?export the Sony ARW fixture directory}"
: "${LUMAHARBOR_APFS_TEST_DIR:?export the APFS fixture directory}"
: "${LUMAHARBOR_EXFAT_TEST_DIR:?export the exFAT fixture directory}"
test -d "$LUMAHARBOR_RAW_FIXTURE_DIR"
test -d "$LUMAHARBOR_APFS_TEST_DIR"
test -d "$LUMAHARBOR_EXFAT_TEST_DIR"
```

通過條件：三條指令皆 exit 0。若 exFAT volume 名稱不同，先確認它確實是本次驗收磁碟，再把後續命令中的 exFAT 路徑改成實際掛載點；報告只記安全代號與 filesystem，不記絕對路徑。

### V0.3 記錄 fixture 安全識別

選定一張本輪會在 iPad 編輯的 Sony `.ARW`，在 Mac 上執行：

```bash
shasum -a 256 "$LUMAHARBOR_RAW_FIXTURE_DIR/_DSC1896.ARW"
diskutil info "$LUMAHARBOR_EXFAT_TEST_DIR" | rg 'File System Personality|Volume Name|Protocol'
```

通過條件：

- 報告只記 `_DSC1896.ARW`、SHA-256 與安全 fixture 代號；
- `diskutil` 顯示預期的 exFAT filesystem；
- 不把完整 fixture 或 volume 路徑貼入報告。

## 4. Gate V1：完整自動驗收

### V1.1 執行 production runner

在 V0.2 的同一個 shell、同一個 worktree 根目錄執行：

```bash
Scripts/run-ipad-library-acceptance.zsh
```

runner 必須依序實際執行：

1. strict-concurrency build；
2. 完整 `swift test`；
3. iPad Simulator `.app` build；
4. `MultiSourceBoundedScanTests`；
5. MVP preflight；
6. MVP acceptance；
7. iPad vertical-slice acceptance；
8. repo fingerprint 與 privacy scan。

用下列命令定位本輪最新 summary：

```bash
LATEST_SUMMARY="$(find .build/ipad-library -name summary.md -type f -print | sort | tail -1)"
test -n "$LATEST_SUMMARY"
sed -n '1,180p' "$LATEST_SUMMARY"
```

通過條件：該 summary 同時符合：

- `Run mode: PRODUCTION`；
- `Overall result: PASS`；
- `Exit code: 0`；
- `Privacy scan: PASS`；
- 七個步驟全部是 PASS，沒有 `SKIPPED` 或 `NOT RUN`；
- `swift test` 與 `MultiSourceBoundedScanTests` 都有非零 executed、0 skipped、0 failures；
- commit 與 V0.1 固定的 commit 相同；
- summary 與 logs 不含私人絕對路徑。

### V1.2 驗證沒有殘留程序與 tracked 變更

```bash
pgrep -fl 'run-ipad-library-acceptance|run-ipad-vertical-slice-acceptance|run-mvp-acceptance|xcodebuild|swift-frontend|xctest'
git status --short --branch
```

通過條件：

- `pgrep` 沒有列出屬於本次 runner 的殘留程序；
- worktree 維持乾淨；
- `.build/` evidence 不得被加入 Git。

若 V1 失敗，保留該 run directory，只把去識別化的摘要與必要錯誤段落寫入報告；不得刪除或覆蓋失敗證據後宣稱重跑成功。

## 5. Gate V2：M1+ iPad 實機驗收

### V2.0 部署與共通設定

1. 用 Xcode 開啟 `Apps/LumaHarborPad.swiftpm`。
2. 選擇 `LumaHarborPad` scheme 與一台 M1 以上真實 iPad。
3. 由使用者在 Signing & Capabilities 選取自己的 Development Team。
4. Build & Run；記錄 iPad 型號、iPadOS、Xcode 版本與驗收 commit。
5. 每個案例分別記錄 PASS／FAIL／NOT RUN、開始與完成時間、操作員及安全的 evidence 名稱。

### V2.1 APFS 加入、掃描與重啟恢復

1. 接上含測試 RAW 的 APFS 外接來源。
2. 在「圖庫」點「加入來源」，從 Files 選取 APFS 測試資料夾。
3. 等待掃描完成，確認來源沒有停在「Scanning」或錯誤狀態。
4. 進入來源與「此照片庫」，確認預期 RAW 出現且縮圖可載入。
5. 強制結束 App，重新開啟。
6. 確認來源、已索引照片、目前 scope 與可用縮圖恢復；不需重新加入來源。

通過條件：來源身份保持一致、不建立重複來源、照片數與重新開啟前一致、索引及已快取縮圖可用。

### V2.2 exFAT 拔除、離線與重新連接

1. 接上含測試 RAW 的 exFAT 外接來源並加入圖庫。
2. 等待掃描完成，打開數張縮圖以建立快取。
3. 安全退出並拔除 exFAT 裝置。
4. 回到 App，確認來源顯示「離線」，既有索引仍可瀏覽，已快取縮圖仍可顯示。
5. 嘗試開啟或匯出離線 RAW，確認 App 顯示可採取行動的離線訊息，不能進入假成功 editor。
6. 重新接上同一顆裝置；使用「重新連接…」選取原資料夾。
7. 確認接回原 `LibraryID`、沒有產生第二份來源，RAW 可再次開啟。
8. 再嘗試選擇同名但不同身份的資料夾，確認系統拒絕誤接。

通過條件：離線保留索引與快取；uncached 內容失敗可理解；重新連接驗證身份；錯誤來源不會被接到原 library。

### V2.3 Files provider 重新授權

1. 在 Files 中選擇一個真實第三方 provider 的資料夾並加入來源。
2. 完成掃描後，透過 provider／系統設定使原授權失效，或撤銷該資料夾存取。
3. 重開 App，確認來源顯示需要存取權，不把資料誤標為已刪除。
4. 執行重新連接／重新授權，選回同一 provider 資料夾。
5. 確認來源回到 online，原索引與 `LibraryID` 延續，未建立副本。

通過條件：授權失效與來源離線狀態可辨識；重新授權需通過身份檢查；失敗時有可採取行動的訊息。

### V2.4 三來源聚合、搜尋、排序與畫面恢復

前置：APFS、exFAT 與 Files provider 三個來源都已加入且 online。

1. 進入「此照片庫」，記錄聚合照片總數與三個來源各自數量。
2. 捲動跨過至少兩個 page，確認沒有肉眼可見的重複、漏項或排序跳動。
3. 以一個確實存在的 Unicode／ASCII 檔名片段搜尋，確認結果只包含相符照片。
4. 依序驗證「檔名（A–Z）」、「檔名（Z–A）」及日期正反向排序。
5. 切到單一來源與資料夾 scope，再回「此照片庫」。
6. 打開一張照片進入 editor，再按「回到相片庫」。
7. 旋轉橫／直向，並至少測一次 Split View 或 Stage Manager 尺寸切換。

通過條件：三來源聚合數正確；搜尋與四種排序穩定；切 scope、進出 editor、尺寸切換後 query、selection 與 scroll anchor 恢復。

### V2.5 Sony `.ARW` 編輯、autosave、重開與 checksum

1. 在 Mac 記錄 `_DSC1896.ARW` 的 SHA-256，並把同一原檔放在本次已加入的來源中。
2. 從 iPad 圖庫打開該 Sony `.ARW`。
3. 依序改動十項既有調整：Exposure、Contrast、Highlights、Shadows、Whites、Blacks、Temperature、Tint、Vibrance、Saturation。
4. 不按另存新檔，返回圖庫，等待 autosave 完成。
5. 強制結束並重開 App，再開啟同一張照片。
6. 確認十項調整值與畫面效果仍在，且「最近編輯」與 edited badge 已更新。
7. 在 Mac 對來源中的同一 `.ARW` 再執行 `shasum -a 256`。
8. 比較操作前後 SHA-256；必要時也比對檔案大小與 modification time。

通過條件：編輯保存於 sidecar／App 狀態，重開後完整恢復；原始 `.ARW` 的 SHA-256 完全相同。任何 checksum 差異皆為阻擋性 FAIL。

## 6. Gate V3：破壞安全與移除來源抽查

對 APFS 或 exFAT 驗測來源先記錄 RAW、sidecar 與 manifest 的檔名／hash，再執行「從 LumaHarbor 移除」。

通過條件：

- 來源從 App registry 與本機索引消失；
- 外接來源上的 RAW、sidecar、manifest 均未被刪除或修改；
- 重新加入後可正常掃描；
- 移除失敗時 UI 不宣稱成功。

## 7. Gate V4：最終 spec 與 pre-landing review

### V4.1 Spec coverage 對照

逐節比對 `docs/superpowers/specs/2026-08-26-ipad-multi-source-photo-library-design.md` 的 §1–§19，於驗收報告記錄：

- 對應 production file；
- 對應 unit／integration／UI／device evidence；
- 明確 deferred 的 §17 項目沒有被誤列為本階段缺陷；
- 任何沒有 code 或 evidence 的 requirement 必須標為 GAP，不能用推論補成 PASS。

### V4.2 變更檔案靜態掃描

```bash
git diff --name-only 150bc7d..HEAD -- ':(glob)Apps/**/*.swift' ':(glob)Sources/**/*.swift' > /tmp/lumaharbor-ipad-production-files.txt
xargs rg -n 'TBD|TODO|FIXME|fatalError|try!|force unwrap' < /tmp/lumaharbor-ipad-production-files.txt
git diff --check 150bc7d..HEAD
```

通過條件：每個命中都已修正，或在驗收報告逐項說明為何安全；`git diff --check` 無輸出且 exit 0。

先前已知命中：`Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/LumaHarborPadApp.swift` 的暫存目錄 fallback 使用 `try! PadAppServices(...)`。此項已改為 `PadAppBootstrapState`：Application Support 初始化失敗時先嘗試暫存 fallback；若 fallback 也失敗，App 顯示 `PadStartupFailureView` 與可本地化的修復提示，而不是在 SwiftUI 畫面出現前強制 crash。V4 仍需重跑本節靜態掃描，確認整個 `150bc7d..HEAD` 範圍沒有新的未說明命中。

### V4.3 獨立 pre-landing review

審查範圍固定為 `150bc7d..HEAD`，至少覆蓋：

1. SQLite v1→v2 migration 原子性與 rollback；
2. keyset cursor 的 tie-break、方向、scope／search 失效契約；
3. bookmark／manifest／provider identity 與同名來源拒絕；
4. scan cancellation、bounded queue、完整掃描才 prune；
5. editor 兩階段切換、autosave 失敗與舊 generation 回寫；
6. remove source 不碰 RAW／sidecar／manifest；
7. runner privacy、signal、timeout、子程序清理與 summary 發布證據協定。

通過條件：沒有 P0／P1 finding；所有阻擋性 finding 已以獨立 commit 修正並重跑 V1 與受影響的 V2／V3 gate。

## 8. 驗收報告寫入規格

更新 `docs/testing/reports/2026-08-26-ipad-multi-source-library.md`，至少新增：

1. 驗收日期、操作員、完整 commit、Mac／iPad／OS／Xcode；
2. RAW／APFS／exFAT／Files provider 的安全代號與 filesystem；
3. V1 最新 summary 的安全相對路徑與逐步結果；
4. V2.1–V2.5、V3 每項 PASS／FAIL／NOT RUN 與證據；
5. Sony ARW 操作前後 SHA-256；
6. V4 spec coverage 與 review finding 結論；
7. remaining concerns，區分阻擋項目與可接受 P2；
8. 最終結論只能是 `APPROVED`、`BLOCKED` 或 `REJECTED`。

## 9. 最終完成條件

只有以下條件全部成立，才可將 iPad 多來源 RAW 圖庫標為完成：

- V0–V4 全部 PASS；
- 最新 production summary 為 PASS，沒有 skipped／not-run；
- 五項 M1+ iPad gate 全部 PASS；
- Sony `.ARW` 操作前後 checksum 相同；
- 移除來源沒有修改任何來源檔案；
- pre-landing review 沒有未解決的 P0／P1；
- 驗收報告 privacy scan 乾淨；
- worktree 乾淨，且未進行未授權的 push、merge 或 rebase。
