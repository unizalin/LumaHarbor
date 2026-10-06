# Brush raster correctness follow-up 驗收報告

日期：2026-10-06

狀態：`DONE_WITH_CONCERNS`

## 1. 驗證對象

- Branch：`codex/brush-performance-acceptance-repair`
- Scalar baseline B：`1de07dcfeb2ed217a75d1c04978da6a5936f379a`
- 原 optimized candidate U：`26c3390ba59e0e2ae416618d6e832a5c0eeba98d`
- 追補規格：`a2cf22266828f16a68d857df92c3a6c2c2cbf654`
- 最終產品與證據 SHA：`4e74bf3`
- 狀態沒有提升為 READY：必要的真實 RAW、原尺寸 export/RSS、人工裝置與獨立 reviewer gate 尚未全部執行。

## 2. 實作結果

| 階段 | Commit | 結果 | 內容 |
| --- | --- | --- | --- |
| F1 像素正確性 | `29718d2` | PASS | 修正跨垂直 tile 的全圖 row mapping；新增直接 R8 oracle、127/128/129/240/256/257 等高度、非零重疊 masks、正負原點與 sync/async 比對。 |
| F2 標準 Release | `bc89693` | PASS | 六個 EditorSession internal test helper 不再依賴全域 `-DDEBUG`；acceptance script 移除該 workaround。 |
| F3 取消生命週期 | `1ded16a` | PASS | 新增 per-invocation stage/worker observer、validation/sampling cooperative cancellation、preview/export 注入點與真正父 Task 取消測試。 |
| F4 可重現證據 | `c425cb7` | PARTIAL PASS | 新增 B/O ABBA runner、schema、baseline testability patch、取消延遲及記憶體診斷；正式 warm synthetic ABBA 通過，其他必要情境仍有 NOT RUN。 |
| F4 證據完整性 | `4e74bf3` | PASS | analyzer 改為拒絕缺 mandatory 欄位、unexpected 欄位、錯誤 order/round/maskCount，以及不一致的 harness、instrumentation 或 product SHA。 |

F1 的 RED 是實際像素 assertion failure：U 上兩個案例分別有 61,680 與 66,049 bytes 差異。修正後 focused matrix 19/19 PASS。這不是編譯失敗或 sync/async 互相比對。

F2 的 RED 是移除 `-DDEBUG` 後標準 Release test target 因六個 helper 缺失而編譯失敗；GREEN filtered Release 1/1 PASS，最終完整標準 Release suite 亦通過。

F3 已涵蓋 sync raster、async conversion、三個 active masks 且至少兩個 worker、validation、sampling、pre-cancel、PreviewScheduler A→B stale suppression，以及 6000×4000 export 取消後無 final/tmp 發布。50-cycle 診斷是同程序交替 subject 並直接取消 renderer；它不等同於 50 次完整 PreviewScheduler 切圖流程，因此正式 `PERF-MEM-50-CANCEL` 不以此宣告完成。

## 3. B/O warm ABBA 結果

正式命令以 4 blocks、warm scenario、0/1/10 masks 執行兩輪；round 1 為 `B O O B`，round 2 為 `O B B O`。共接受 96 筆 record，baseline SHA、product SHA、harness SHA 與 instrumentation digest 均一致；validation `PASS`，整體仍為 `DONE_WITH_CONCERNS`。

| Round | Gate | O p50 | O p95 | 結果 |
| --- | --- | ---: | ---: | --- |
| 1 | empty total | 2.253 ms | 2.392 ms | PASS |
| 1 | 1 mask incremental | 11.525 ms | 11.730 ms | PASS |
| 1 | 10 masks incremental | 24.201 ms | 25.128 ms | PASS |
| 2 | empty total | 2.151 ms | 2.452 ms | PASS |
| 2 | 1 mask incremental | 11.719 ms | 11.525 ms | PASS |
| 2 | 10 masks incremental | 24.343 ms | 26.845 ms | PASS |

| Round | Masks | B peak RSS | O peak RSS | 結果 |
| --- | ---: | ---: | ---: | --- |
| 1 | 0 | 46,776,320 | 46,727,168 | PASS |
| 1 | 1 | 66,813,952 | 52,953,088 | PASS |
| 1 | 10 | 85,983,232 | 109,625,344 | PASS；低於 B + 32 MiB |
| 2 | 0 | 46,759,936 | 46,727,168 | PASS |
| 2 | 1 | 66,797,568 | 52,969,472 | PASS |
| 2 | 10 | 85,983,232 | 111,640,576 | PASS；低於 B + 32 MiB |

另有 Release 診斷：preview cancellation p95 0.080 ms、24MP export cancellation p95 0.309 ms；50 個 measured cycles 加 5 次 warmup 後，workers 55/55、active 0，settled RSS 比 warm plateau 增加 16 KiB。這些結果支持 cancellation lifecycle，但不取代下表標為 NOT RUN 的完整產品 gate。

analyzer 的 fail-closed 測試另以完整 96 筆資料得到 exit 0；移除一個 mandatory 欄位後得到 exit 1、validation `FAIL`，僅接受 95 筆資料。

## 4. 最終 SHA 自動驗證

主要命令如下；效能 raw artifact 保存在未提交的本機暫存目錄，未加入 Git：

```sh
LUMAHARBOR_BRUSH_ABBA_BLOCKS=4 \
LUMAHARBOR_BRUSH_ABBA_SCENARIOS=warm \
LUMAHARBOR_BRUSH_ABBA_MASK_COUNTS='0 1 10' \
LUMAHARBOR_BRUSH_ABBA_RUN_ROOT=/private/tmp/LumaHarborBrushABBAFormal-c425cb7 \
Scripts/run-brush-performance-abba.sh

swift test --scratch-path /private/tmp/LumaHarbor-F5-Debug-4e74bf3
swift test -c release --scratch-path /private/tmp/LumaHarbor-F5-Release-4e74bf3
CLANG_MODULE_CACHE_PATH=/private/tmp/LumaHarbor-F5-ClangCache-4e74bf3 \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/LumaHarbor-F5-SwiftPMCache-4e74bf3 \
swift build --scratch-path /private/tmp/LumaHarbor-F5-Strict-4e74bf3 \
  -Xswiftc -strict-concurrency=complete

LUMAHARBOR_SCRATCH_PATH=/private/tmp/LumaHarbor-F5-Mac-4e74bf3 \
Scripts/build-app-bundle.sh release
xcodebuild -project Apps/LumaHarborPad.xcodeproj -scheme LumaHarborPad \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /private/tmp/LumaHarbor-F5-Sim-4e74bf3 \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Apps/LumaHarborPad.xcodeproj -scheme LumaHarborPad \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /private/tmp/LumaHarbor-F5-Device-4e74bf3 \
  CODE_SIGNING_ALLOWED=NO build

codesign --verify --deep --strict --verbose=2 build/LumaHarbor.app
Scripts/verify-release-privacy.sh build/LumaHarbor.app
LUMAHARBOR_RELEASE_DIR=/private/tmp/LumaHarbor-F5-Unpublished-4e74bf3 \
Scripts/package-mac-release.sh release
git diff a2cf222..HEAD --check
```

| 驗證 | 結果 |
| --- | --- |
| `swift test --scratch-path <fresh-debug>` | PASS；2,708 executed、21 skipped、0 failures |
| `swift test -c release --scratch-path <fresh-release>` | PASS；2,708 executed、21 skipped、0 failures |
| `swift build --scratch-path <fresh-strict> -Xswiftc -strict-concurrency=complete` | PASS；既有 Swift 6 warnings 保留 |
| `Scripts/build-app-bundle.sh release` | PASS；Release app 組裝並 ad-hoc signed |
| generic iOS Simulator build，`CODE_SIGNING_ALLOWED=NO` | PASS |
| generic iOS device build，`CODE_SIGNING_ALLOWED=NO` | PASS |
| `codesign --verify --deep --strict --verbose=2 build/LumaHarbor.app` | PASS |
| `Scripts/verify-release-privacy.sh build/LumaHarbor.app` | PASS |
| fresh unpublished `Scripts/package-mac-release.sh release` | PASS；ZIP、SHA-256、簽章與隱私掃描完成；notarization SKIPPED |
| `git diff a2cf222..HEAD --check` | PASS |
| 新增差異中的 private user/mount/temp-home/team scan | PASS |

第一次 strict-concurrency 重跑因沙箱禁止寫入使用者 module cache 而 exit 1；將 `CLANG_MODULE_CACHE_PATH` 與 `SWIFTPM_MODULECACHE_OVERRIDE` 指向工作樹外的暫存目錄後，同一原始碼驗證 PASS。此失敗不涉及編譯器診斷或程式碼變更。

## 5. Gate 狀態與限制

| Gate | 狀態 | 說明 |
| --- | --- | --- |
| PIX-A～D | PASS | 直接 R8、全圖 row flip、重疊 mask order、sync/async 獨立 oracle 已驗。 |
| PIX-E | PASS WITH EXISTING COVERAGE | 既有 geometry mapping 回歸與完整 suites 通過；本輪沒有新增完整人工 landmark corpus。 |
| REL | PASS | 不需全域 DEBUG define 的完整標準 Release suite 通過。 |
| CAN-A～E | PASS | 真正父 Task 取消、worker join、stale suppression、export cleanup 已自動驗證。 |
| PERF-EMPTY / PERF-PREVIEW / preview RSS | PASS（warm synthetic） | 兩輪 96-record B/O ABBA 通過。 |
| PERF-COVERAGE | NOT RUN | 公開 B/O harness 只量 total preview，未產生可直接比較的 B/O coverage stage。O-only coverage correctness 已有測試。 |
| cold / changed / appended / stress ABBA | NOT RUN | runner 與 schema 已支援，正式樣本未執行。 |
| INTERACTIVE-150 | NOT RUN | 缺真實 RAW production preview 的 0/1/10 masks、cold/warm/changed matrix。 |
| PERF-EXPORT / PERF-MEM-EXPORT | NOT RUN | 缺 B/O 原尺寸真實 RAW export 與程序 peak RSS。 |
| PERF-MEM-50-CANCEL | NOT RUN | 有直接 renderer 50-cycle 診斷，但未完成規格要求的完整 scheduler 切圖流程 gate。 |
| PERF-CANCEL | PARTIAL PASS | synthetic preview/export 延遲通過；真實 RAW 原尺寸與完整正式 artifact 尚未完成。 |
| PERF-UI | NOT RUN | 未在 GUI 裝置執行 heartbeat 與 30 次操作。 |
| RawFixtureTests（最終 SHA） | NOT RUN | 本次環境未提供 `LUMAHARBOR_RAW_FIXTURE_DIR`；未把私人路徑寫入文件或 Git。 |
| Mac／實體 iPad／Pencil／輸入矩陣／灰卡 | NOT RUN | 無人工解鎖與實體驗收。Simulator/device generic build 不能取代操作驗收。 |
| 獨立 reviewer | NOT RUN | Sol 為主要 writer，Codex root 做整合與證據 validator review；仍不構成規格要求的非 writer 獨立覆核。 |
| notarization | SKIPPED | 本輪只產生本機未發布 alpha 封裝。 |

## 6. 判定與下一步

跨垂直 tile 像素錯位、標準 Release testability、取消生命週期及 warm synthetic B/O 證據已修正並通過。由於真實 RAW、原尺寸 export/RSS、完整情境 ABBA、人工裝置與獨立審查仍缺，分支保持 `DONE_WITH_CONCERNS`，不標示整合 READY。

下一個有界工作是提供私有 RAW fixture 環境後，在同一參考機器對 B/O 執行 0/1/10 masks 的真實 RAW preview，以及一／十 mask 原尺寸 export 與 peak RSS；接著再跑 cold、changed、appended、stress 正式矩陣。
