# LumaHarbor Mac-first MVP 驗收報告

複製本檔為 `docs/testing/reports/YYYY-MM-DD-mvp-acceptance.md`（`reports/` 目錄未加入 Git 追蹤時請先建立），逐項填寫。每一項都要有實際證據（log 路徑、指令輸出、人工觀察紀錄），不得以「應該可以」或「typecheck 過」代替真正執行結果。

> 安全提醒：本報告只記錄安全代號、雜湊與檔案系統類型，**絕不**貼上使用者本機的完整私人路徑（fixture 資料夾、APFS／exFAT 測試資料夾）。私人 `.ARW` 檔案本身永不進入本報告或 Git。

## 0. 摘要

| 項目 | 內容 |
|---|---|
| 驗收日期 | |
| 驗收人員 | |
| 對應 spec | `docs/superpowers/specs/2026-08-15-mac-first-mvp-acceptance-plan.md` |
| 基準 commit | |
| 整體結論 | ☐ MVP 完成　☐ 部分完成（見 §9 未清空項目）　☐ 未完成 |

## 1. 硬體與作業系統

| 項目 | 指令 | 結果 |
|---|---|---|
| 硬體型號 | | |
| `uname -m` | `uname -m` | |
| macOS 版本 | `sw_vers` | |

## 2. Xcode 與 Swift 工具鏈

| 項目 | 指令 | 結果 |
|---|---|---|
| Xcode 版本 | `xcodebuild -version` | |
| `xcode-select -p` | `xcode-select -p` | |
| Swift 版本 | `swift --version` | |

## 3. Fixture 與測試目錄識別（不含私人絕對路徑）

| 項目 | 記錄方式 | 值 |
|---|---|---|
| RAW fixture 安全代號 | 人工指定的代號（例如 `fixture-set-A`），不是路徑 | |
| Sony `.ARW` 檔案數 | `find` 或 runner preflight 輸出的計數 | |
| 各 fixture SHA-256 | `shasum -a 256 <file>`，只記雜湊與檔名，不記完整路徑 | |
| 各 fixture 檔案大小（bytes） | | |
| 各 fixture 修改時間（測試前） | `stat -f %Sm` | |
| 各 fixture 修改時間（測試後） | 必須與測試前完全一致；不一致即 P0 | |
| 橫向樣本 | ☐ 已含 | |
| 直向樣本 | ☐ 已含 | |
| 高 ISO 樣本 | ☐ 已含　☐ 無 | |
| 高光／陰影明顯樣本 | ☐ 已含　☐ 無 | |

## 4. APFS 與 exFAT 測試目錄

| 項目 | APFS | exFAT |
|---|---|---|
| Runner 回報的 filesystem 類型 | | |
| 專用測試目錄是否僅含 fixture 副本 | ☐ 是 | ☐ 是 |
| Gate E 十項是否全部執行（見 §7） | ☐ 是 | ☐ 是 |

## 5. 自動化測試執行（Gate B：完整 XCTest baseline）

執行：

```sh
Scripts/run-mvp-acceptance.zsh
```

或手動：

```sh
swift test -Xswiftc -strict-concurrency=complete
```

| 項目 | 數量 |
|---|---|
| Executed | |
| Passed | |
| Failed | |
| Skipped — bookmark 相關 | |
| Skipped — read-only 相關 | |
| Skipped — RAW fixture 相關 | |
| Skipped — 其他（逐一列出原因） | |
| Crash / hang / data race / sanitizer 訊息 | ☐ 無　☐ 有（見附錄 log） |

失敗案例逐一列出完整測試名稱與失敗訊息：

```
（貼上失敗清單，或註明「無失敗」）
```

Log 路徑（repo-ignored，例如 `.build/mvp-acceptance/<timestamp>/swift-test.log`）：

## 6. Sony `.ARW`／Metal／匯出（Gate D：`RawFixtureTests`）

執行：

```sh
LUMAHARBOR_RAW_FIXTURE_DIR=/path/to/private/fixtures swift test --filter RawFixtureTests
```

`RawFixtureTests` 8 個既有案例逐一記錄（不得 skip）：

| # | 測試名稱 | 結果 | 備註 |
|---|---|---|---|
| 1 | `testEveryFixtureDecodes` | ☐ Pass ☐ Fail | |
| 2 | `testSonyArwReportsPlausibleMetadata` | ☐ Pass ☐ Fail | |
| 3 | `testPreviewDecodeHonoursTheRequestedSize` | ☐ Pass ☐ Fail | |
| 4 | `testFullDecodeReturnsNativeResolution` | ☐ Pass ☐ Fail | |
| 5 | `testWhiteBalanceOffsetChangesTheRender` | ☐ Pass ☐ Fail | |
| 6 | `testFullResolutionExportMatchesTheSourceDimensions` | ☐ Pass ☐ Fail | |
| 7 | `testExportingNeverModifiesTheOriginal` | ☐ Pass ☐ Fail | |
| 8 | `testPreviewSchedulerDeliversARenderedFrameForARealRaw` | ☐ Pass ☐ Fail | |

人工補驗（無法自動化的視覺判斷）：

| 項目 | 結果 |
|---|---|
| 方向（EXIF orientation）正確 | ☐ 是 ☐ 否 |
| 曝光看起來合理 | ☐ 是 ☐ 否 |
| 色偏（white balance）看起來合理 | ☐ 是 ☐ 否 |
| 無明顯 banding | ☐ 是 ☐ 否 |
| 黑白點調整有效且無明顯錯誤 | ☐ 是 ☐ 否 |
| 高光／陰影調整有效且無明顯錯誤 | ☐ 是 ☐ 否 |
| 匯出 JPEG 標記 sRGB | ☐ 是 ☐ 否 |
| 匯出前後 RAW fingerprint／修改時間完全一致 | ☐ 是 ☐ 否 |

## 7. APFS／exFAT 與 bookmark lifecycle（Gate E）

對 APFS 與 exFAT 各完整執行一次，逐項記錄：

| # | 情境 | APFS 結果 | exFAT 結果 | 備註 |
|---|---|---|---|---|
| 1 | 由系統面板加入專用測試資料夾 | | | |
| 2 | 增量掃描、縮圖逐步出現 | | | |
| 3 | 編輯照片後 `.lumaharbor` sidecar 落地 | | | |
| 4 | 關閉並重啟 App，bookmark／selection／edit 恢復 | | | |
| 5 | 刪除本機 SQLite 與 cache 後重建，PhotoID／edits 不變 | | | |
| 6 | 資料夾改名後 relink，不猜路徑、不另建 identity | | | |
| 7 | App 開啟時拔除 SSD：保留 cached thumbnail、不 crash、未保存 edit 可重試 | | | |
| 8 | 重接 SSD 並重新授權，library identity 與 sidecar edit 保留 | | | |
| 9 | 唯讀情境：瀏覽可行，保存／匯出顯示 actionable error，無偽成功 | | | |
| 10 | 損壞 RAW／sidecar：單檔失敗、掃描繼續、sidecar 隔離而非覆寫 | | | |

任何 crash、原檔變動、PhotoID 漂移、edit 遺失或偽成功都是 P0，記入 §9。

## 8. UI 與效能（Gate F）

### 8.1 人工功能矩陣

| 項目 | 結果 |
|---|---|
| 十個調整項目即時預覽與各自重設 | ☐ 通過 ☐ 未通過 |
| 原圖比較、Undo、Redo、整張重設正確 | ☐ 通過 ☐ 未通過 |
| 滑桿後立即切換照片：edit 先保存；保存失敗停留原照片 | ☐ 通過 ☐ 未通過 |
| 單張 JPEG 匯出、同名流水號、取消清除暫存檔、Finder 顯示正確 | ☐ 通過 ☐ 未通過 |
| offline／read-only／unsupported／corrupt／disk-full 錯誤都有下一步 | ☐ 通過 ☐ 未通過 |

### 8.2 Apple Silicon + Instruments

| 指標 | 目標 | 實測 | 結果 |
|---|---|---|---|
| Cached thumbnail 延遲 | ≤ 300 ms | | ☐ 達標 ☐ 未達標 |
| Slider preview 延遲 | ≤ 150 ms | | ☐ 達標 ☐ 未達標 |
| 快速切換照片 100 次後 in-flight work／記憶體 | 不持續線性成長 | | ☐ 通過 ☐ 未通過 |
| 大資料夾掃描 high-water | bounded；main thread 無 RAW decode／hash／export | | ☐ 通過 ☐ 未通過 |

效能未達標但 UI 仍可回應、記憶體未線性成長、工作仍可取消 → 記為 P1；否則升級為 P0/blocker。

## 9. P0／P1／P2 清單

| 等級 | 描述 | 對應 Gate | 狀態 |
|---|---|---|---|
| P0 | | | |
| P1 | | | |
| P2（MVP 後可接受的已知限制） | | | |

## 10. 主規格 §13 十項 sign-off

對照 `docs/superpowers/specs/2026-08-13-mac-first-mvp-design.md` §13。

| # | 條件 | 證據 | 結果 |
|---|---|---|---|
| 1 | 可選擇外接 SSD 目錄並在 App 重啟後恢復授權 | | ☐ 通過 ☐ 未通過 |
| 2 | 可增量掃描並顯示 Sony `.ARW` 縮圖 | | ☐ 通過 ☐ 未通過 |
| 3 | 第 6.2 節所有調整都能即時預覽 | | ☐ 通過 ☐ 未通過 |
| 4 | 原圖比較、Undo、Redo 與重設皆有測試 | | ☐ 通過 ☐ 未通過 |
| 5 | 調整自動保存至 `.lumaharbor`，重啟後結果一致 | | ☐ 通過 ☐ 未通過 |
| 6 | 原始 `.ARW` 的內容與修改時間不被 App 改變 | | ☐ 通過 ☐ 未通過 |
| 7 | 可從完整解析度 RAW 匯出帶 sRGB profile 的 JPEG | | ☐ 通過 ☐ 未通過 |
| 8 | SSD 拔除、不支援 RAW、損壞 RAW 或唯讀磁碟不會導致崩潰 | | ☐ 通過 ☐ 未通過 |
| 9 | 本機 SQLite 與快取刪除後可重建 | | ☐ 通過 ☐ 未通過 |
| 10 | 核心單元與整合測試通過，且無已知資料損毀問題 | | ☐ 通過 ☐ 未通過 |

十項全部通過，且 §9 沒有未清空的 P0/P1，才可標記 MVP 完成。

## 附錄：原始 log 位置

Runner 產出的原始 log 都在 repo-ignored 的 `.build/mvp-acceptance/<timestamp>/` 下，本報告只引用其相對路徑，不搬移或貼上私人路徑內容：

- `preflight.log`
- `strict-build.log`
- `swift-test.log`
- `raw-fixture-test.log`
- `summary.md`
