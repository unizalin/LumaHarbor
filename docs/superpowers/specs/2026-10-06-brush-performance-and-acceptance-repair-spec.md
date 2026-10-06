# LumaHarbor 後續修正规格：筆刷效能、取消與驗收補齊

- 日期：2026-10-06（Asia/Taipei）
- 任務識別：`LH-BRUSH-PERF-ACCEPTANCE-20261006`
- 版本：v1.0
- 狀態：`SPEC ONLY`；本輪只建立文件，未修改產品或重跑產品驗收。
- 目的：讓已整合的新調整筆刷降低運算與記憶體成本，能在繪製中途確實取消，並補齊操作、色彩與獨立審查證據。
- 本文件提出的新數值門檻是後續實作的驗收要求，不是已達成結果。

## 1. 文件位置、依據與權威

本文件是此次修正任務的正式 repo-relative spec，與產品程式碼同一個 checkout；後續實作、測試與報告都必須以此文件為範圍基準。

歷史別名：`CANDIDATE` 指主線筆刷整合基線；`MAIN` 指正式 `origin/main`；`SOURCE` 指唯讀來源；`TARGET` 指本次修正工作樹。下文程式路徑均相對於目前 Git root。下文程式路徑相對於 CANDIDATE／TARGET 的 Git root。

必要依據：

1. [整合驗收報告](../../testing/reports/2026-10-05-mainline-white-balance-brush-integration.md)。
2. [整合交接文件](../../coordination/2026-10-06-mainline-white-balance-brush-integration-handoff.md)。
3. [主線整合規格](2026-10-05-mainline-white-balance-brush-integration-spec.md)，尤其 §7、§12、§13。
4. [筆刷四項修正規格](2026-10-02-brush-mask-review-repair-spec.md)，尤其 FIX／GEO／GEST／DATA／PIPE 矩陣。
5. [白平衡與輸入修正规格](2026-09-29-white-balance-and-input-correctness-repair-spec.md)、[白平衡與輸入追補規格](2026-09-29-white-balance-and-input-review-followup-spec.md)，保留原 26 項驗收及其指定指標。
6. CANDIDATE 的 `AGENTS.md`、共用讀取／Git 協作規則、`CURRENT.md`、`DECISIONS.md`。
7. [修圖介面與數值操作規格](2026-09-29-lightroom-inspired-editor-ui-spec.md)，保留 D65 Lab／ΔE00 與至少 30 次前景操作的量測契約。

本文件補充效能量測、取消與缺漏驗收；不取代 Sidecar v5、rendererVersion 1、白平衡、座標、像素、儲存及 Native fail-closed 契約。歷史 `DONE_WITH_CONCERNS` 只表示交付了候選，不等同整合 READY；不得由報告摘要推導所有原矩陣子項已 PASS。

## 2. 已查證起點與證據限制

### 2.1 Git 快照

2026-10-06 本機唯讀核對結果：

| 項目 | 快照 |
| --- | --- |
| CANDIDATE branch | `codex/mainline-wb-brush-integration` |
| CANDIDATE HEAD | `1de07dcfeb2ed217a75d1c04978da6a5936f379a` |
| 驗收產品／測試 SHA | `0cd6eba4a8c75746f7c7cefa24a4c7a85f6b114d`；其後至 HEAD 僅三份文件異動 |
| 本機 origin/main | `82542e73aae8f16b0ba7e4d9d36a8a42451a7319`；本輪未連線查遠端，不宣稱為即時遠端 SHA |
| 差異／工作樹 | ahead 25、behind 0；CANDIDATE 乾淨 |
| 歷史回歸證據 | 完整 suite 2,687 executed、17 skipped、0 failures；strict build、Mac Release、generic iPad builds、隱私及封裝通過 |
| 歷史 RAW 證據 | 10 executed、1 skipped、0 failures；reference export opt-in 未執行 |

上述測試數字引用報告／交接，不是本文件撰寫時重新執行的結果。SOURCE 原有 dirty/untracked 屬於既有作者，後續不得修改。

### 2.2 問題與優先順序

| ID | 優先 | 已知現象／證據 | 後續工作 |
| --- | --- | --- | --- |
| EVID-01 | P0 | 報告量測缺可提交的 probe、完整 build configuration 與逐樣本順序；本輪未找到先前暫存 probe | 先建立可重現 Debug／Release 基線，不能直接把舊毫秒數當 Release SLA |
| PERF-01 | P1 | 1600px 一個 mask p50 933.9／943.8 ms；十個 7,993.1／8,008.0 ms | 分段計時，再優化 coverage |
| PERF-02 | P1 | 6000×4000 一／十 mask 匯出 9.1／87.2 秒；峰值 484.7／691.2 MiB | 降低 full-frame 暫存與 per-mask 成本；重測原尺寸 |
| CANCEL-01 | P1 | `renderCoverage`／`sample`／R8 轉換長迴圈沒有取消檢查 | 加入有界協作取消，測真正進入 coverage 後的取消 |
| CTX-01 | P1 | `ImageRenderService.configured(for:)` 每次建立新 service／CIContext | 查明每幀建立成本；固定色彩設定可重用，切換設定不可誤用 |
| UI-01 | P1 | Mac 操作 NOT RUN；Simulator 僅首屏，真機未驗 | 補實際動作、持久化與輸入矩陣 |
| REVIEW-01 | P1 | Task 7 的獨立 reviewer 因額度不足未完成 | 安排唯讀獨立審查，保存 finding 與修正對照 |
| WB-01 | P1 | 灰卡 E／D65 Lab／ΔE00 尚缺證據 | 有合格素材才執行；缺素材明確 NOT RUN |
| LR-01 | 另案依賴 | 正式 Lightroom Gate 2 未在本候選重跑 | 保持原 FAIL／NOT RUN，不啟用 Adobe renderer |

取消歷史 p50 32.509 ms、p95 153.295 ms 沒有 coverage 階段進入證據，不能證明長迴圈可取消，也不能單憑耗時把尾端延遲歸因於 RAW decode。報告聲稱 context 重用，但目前 `configured(for:)` 實際重建 context；需修正未來報告的量測敘述。

## 3. 範圍與執行基準

本次 spec 不建立產品 branch/worktree、不發布 Issue、不啟動實作、不修改既有報告的歷史數據。後續程式開發先執行 P0：

1. 重新核對 MAIN、CANDIDATE、SOURCE 的 HEAD、工作樹及持有者；保存私有的前後內容 manifest，公開文件只保留去識別化結果。
2. 若最新 MAIN 已包含候選的等價行為，依共用規則從該 MAIN 建立 TARGET。
3. 若尚未包含候選，CANDIDATE 是本次效能比較的必要父版本。只有在使用者已明確授權延續此未合併候選時，才從上述候選 SHA 建隔離 TARGET，記錄此相依工作例外；沒有該授權時先完成量測／唯讀準備，再取得基準決定。不可自動 merge/rebase，也不可在缺少筆刷功能的 MAIN 上聲稱修復完成。
4. TARGET 單一 writer；提交時只 stage 明確檔案。保存 CANDIDATE 與 SOURCE，不因開始下一階段覆蓋它們。

包含：可重現 benchmark、coverage 運算／記憶體優化、內部取消點、必要 context 重用、相關回歸、實際 Mac/iPad 驗收、獨立審查與文件。UI 驗收找到的直接相關缺陷，以可重現案例修正。

不包含：新增遮罩功能、改 UI 架構、改資料格式或 rendererVersion、RAW decoder／色彩校準重寫、Adobe renderer 啟用、版本升級、公開發布、主線合併、日常 App 替換。正式 Lightroom Gate 2 另案維持原狀。

## 4. 技術方案與不可退化契約

### 4.1 先量測，再改實作

觀察到的主要成本候選為：每個 mask 配置 `width × height` 個 CGFloat、逐 stamp 的 bounding-box 像素迴圈與 `hypot`、全圖 `flatMap/map` 轉 R8、每次 render 重建 context。這是程式碼分析，尚不是 profiler 證明；P0 需提供各階段時間及配置證據。

決定第一版採**分塊 CPU coverage、維持既有精度與操作順序**，不先加入 GPU kernel 或持久化 coverage cache。這讓 scalar oracle 可直接比較，取消點與暫存上限也能明確測試。若 Release 實測仍未達標，保留 FAIL，先提出有 profiler 支持的後續方案，不降低解析度、刪點或放寬像素標準來過關。

### 4.2 Coverage 與記憶體

- 保留 `BrushMaskRenderer.applyValidated` 的 throwing 產品入口；preview／export 不改用吞錯誤並回傳原圖的 convenience API。
- 以固定 128×128 pixel tile 為第一版工作區，按 tile 內原 stroke／sample 順序累積；每個 sample 仍只作用於原本圓形 support 及 feather band。
- 使用與既有 CGFloat 等價的精度；不能逐 stamp 先轉 UInt8，也不能為平行化交換 paint／erase 的順序。每個像素最後才 clamp、round、寫入 R8，保留原 row flip、非零 extent 及 gray color space。
- 依 stamp bounding box 派送到相交 tiles；避免每個 tile 重算全 path。索引、樣本與輸出 buffer 都需納入記憶體統計，不能用巨大索引取代原 full-frame alpha。
- coverage 暫存上限：一張 width×height 的 R8 output 加上 bounded tile scratch 及有界 sample metadata。不得同時保留每個 mask 的 full-frame CGFloat alpha；CIImage graph 必要保留的 R8 backing 另計。
- width／height 有限、正數，Int 轉換及乘積溢位先拒絕；無法安全配置時明確錯誤，不降成原圖。極大 extent 的測試不實際配置巨量記憶體。
- 不新增跨照片 coverage cache。未來若另案加 cache，必須以完整筆畫值、extent、mapping、renderer version 等 key 管理，並有 byte budget；UUID 相同不代表內容相同。

### 4.3 Context 重用

- `configured(for:)` 在有效 working-color-space ID、output-transform ID 與 device preference 相同時重用現有 service/context；任一項不同都建立正確設定的 service。
- 保留 recipe resolution、decode result recipe、Native fallback、輸出色彩空間與 profile request，不為重用省略 resolver。
- 以建立次數／service identity 和兩種不同 recipe 的實際像素／標記測試驗證，不只量測耗時。
- 不引入無界全域 context pool；需要跨 render 保留不同設定時，先以有界單一／少量 slot 設計並補併發隔離測試。

### 4.4 取消、工作執行與發布

- 保留 `runOffActor` 的 parent-to-detached cancellation forwarding。
- 在 validation 大迴圈、sampling、tile/stamp rasterization、R8 conversion 各階段加入檢查；最遲每 4,096 次 pixel／point 迭代及每個 tile 邊界檢查一次。不能只有整個 mask 前後檢查。
- 取消必須拋出 `CancellationError`，export 沿用 `.cancelled` 映射與 temporary-file cleanup；不得發布部分 coverage、成功 export 或錯誤的「已儲存」。
- scheduler 保留 subject／generation／contextID 過期拒絕；舊工作收到 cancel 但仍運算的實際 task 數另測，不能只用 `inFlightCount` 字典數量聲稱沒有堆積。
- 以可注入的 test-only stage probe／barrier，確定進入 coverage 中段後取消；不得只在 Task 建立後 sleep 1 ms，也不得吞掉所有錯誤便算成功。
- 測 preview 與 full export；RAW decode／CI encode 等平台不可搶占區段分開記錄，取消後下一個可控邊界必須退出。
- profiling 確認 decoding、coverage 與 export encoding 都不在 main thread；快速切圖後不得晚到舊 image／histogram／error。

### 4.5 像素與資料保真

固定 pipeline：RAW recipe／global → 新 brushMasks → geometry → 舊 local adjustments → preview options 或 export resize／encode。

- 保存 v5、rendererVersion 1、mask/stroke ID、順序及精確值；零資料遷移，載入／取消／no-op 不寫回。
- 用 CANDIDATE 凍結的 scalar coverage 作 test-only oracle，加上獨立白／灰／非對稱控制影像；不能讓 expected 與 optimized 共用待驗證核心。
- coverage 同尺寸每通道最大差 ≤1/255；與舊版相同取樣／精度路徑目標為 R8 byte-identical，任何差異都列 max error 與位置。
- 繼承原 spec：未改區域 ≤1/255、落點 ≤1 output pixel、連續座標 round-trip ≤來源短邊 1e-6；不同解析度依 source landmarks 比較中心、遮罩外、feather 邊界。
- 覆蓋 paint→erase→paint、低 flow、feather 0／1、單點、重複點、稀疏／密集共線、奇偶尺寸、非零 extent、disabled／neutral／空 mask、未知 version 與非法 patch。
- 完整 geometry 含 flip、90/180/270、非中央 crop、straighten、perspective、corner pins 與組合；不能修掉 mapper 檢查以取得較快結果。
- 現有 coverage 未直接消費 density／pressure。此輪效能修正不得順便重新解釋 rendererVersion 1 的已存值；若原功能 spec 要求對應像素效果，須新增獨立 correctness finding，保留該功能 gate 未完成，另定相容修正與版本政策。Pencil 輸入可用不等於壓力顯色已驗收。

## 5. 可重現效能協定

### 5.1 產物與工作負載

將 benchmark harness、生成器、scalar oracle、JSON schema、操作說明提交到 TARGET。不得依賴消失的暫存 probe。建議新增 `Tests/RawProcessingCoreTests/BrushMaskPerformanceTests.swift`、`Tests/LumaHarborIntegrationTests/BrushMaskPerformanceAcceptanceTests.swift` 與 `Scripts/run-brush-performance-acceptance.sh`。

- Baseline B：CANDIDATE exact SHA；Optimized O：TARGET exact SHA。MAIN 空筆刷另列相容回歸，不拿沒有新筆刷的 MAIN 作有效負載對照。
- 固定 seed、固定 UUID、固定 mask 順序；主 workload 為 0／1／10 masks，每 mask 10 paint strokes，每 stroke 100 points。
- 主 workload 路徑：mask m、stroke s、point j；`x=0.05+0.009*j`、`y=0.08+((10*m+s)%84)/100`，j=0…99；size=0.018、feather=0.25、flow=0.6、density=0.8、pressure=0.65；mask 偶數 exposure=+0.25、奇數=-0.2。此處凍結新的可重現 workload，不保證與已消失舊 probe 逐 byte 相同。
- 另測 paint／erase 混合、size=1 大筆刷、geometry 非 neutral、單 stroke 追加、只改曝光及首次開圖。所有基準套用完全相同設定。
- synthetic 1600×1067 控制影像量 coverage；真實 RAW 量 1600px production preview 及原尺寸 export，native／decoded／output 尺寸分別記錄。私有 RAW 由環境變數注入，不提交內容、名稱或 digest。

### 5.2 執行與統計

1. Debug 與 Release 分開建置、分表；正式效能判定使用 Release。先完成 B/O build，再計時執行，禁止把 compiler RSS 當 renderer memory。
2. 同一硬體、電源狀態、OS／Xcode、decoder、recipe／effective policy、輸出色彩與尺寸；記錄 thermal state。renderer/context 生命周期一致；context 建立數單獨回報。
3. 每個情境至少一次 warmup；2 輪各至少 8 個有效 B 樣本與 8 個 O 樣本。使用 ABBA 配對區塊，第二輪反向，保留執行順序與所有原始數值。
4. preview 區分 cold、warm unchanged、追加 stroke／修改參數；不能只重播相同 request 或只量 cache hit。B/O 使用相同逐樣本 exposure 序列，neutral 情境維持 exposure=0。
5. 計時必須包含真正產生 CGImage／寫完 export 的 materialization；另列 decode、validation/sampling、coverage、blend/materialization、encode 與總時間。單純建立 lazy CIImage graph 不算 render 完成。
6. p50 為排序後中位數、p95 為 nearest-rank `ceil(0.95*n)`；8 樣本時 p95 就是最大值，必須標明。失敗／取消樣本獨立報告，不能默默丟棄後補測。
7. 原尺寸一／十 mask 的 B/O 每輪至少 3 次 export，報 median、max、peak RSS，不以 n=1 宣稱穩態 p95。每次用新輸出名稱，量測完成包含原子發布。
8. process peak RSS 由已建置測試程序取得；另量 50 次「編輯→取消→切圖」後的存活工作、settled RSS。剔除編譯、Simulator 啟動等干擾須整個配對 round 重跑，保留原失敗紀錄。
9. artifact 記錄 SHA、configuration、scenario、round、order、seed、dimensions、recipe IDs、raw durations、cancel stage/outcome、RSS、result；公開輸出只有 allowlist 欄位，測試原始 log 留私有位置。

### 5.3 本輪新增效能門檻

參考機器為報告的 Apple M4／32 GB；其他機器另外報告，不直接混比。所有值都用本輪重新建立的 Release B/O 比較；下列 absolute／增量預算是本 spec 的工程目標。

| Gate | 每輪判定 |
| --- | --- |
| PERF-EMPTY | O 空筆刷 p50 不慢於 B 超過 `max(5 ms, B p50×5%)`；p95 不超過 B p95＋10 ms |
| PERF-COVERAGE | synthetic 1600px 單 mask coverage p50 ≤20 ms、十 mask ≤80 ms；各情境若 B 已達標，O 仍不可回歸超過 `max(2 ms, B×5%)` |
| PERF-PREVIEW | 有效負載 O 相對 O 空筆刷的端到端增量 p50：一 mask ≤30 ms、十 mask ≤100 ms；p95 增量分別 ≤60／150 ms |
| PERF-EXPORT | 原尺寸一／十 mask 各比 B median 至少改善 50%；若 B 本就 ≤5 秒／≤15 秒，允許改善較少但 O 必須維持該 absolute budget 且無 >5% 回歸 |
| PERF-MEM | preview 峰值 RSS ≤B＋32 MiB；full export ≤B，且 reference 24MP case ≤768 MiB；50 次取消／切圖後 settled RSS 不高於同程序 warm plateau 超過32 MiB |
| PERF-CANCEL | 確定進入 coverage 後，8 次 preview 及8次原尺寸工作取消 p95 ≤100 ms；每次都確認 worker 結束及沒有晚到發布 |
| PERF-UI | 前景 main-runloop 16 ms heartbeat 的額外延遲 p95 ≤50 ms、max ≤100 ms；與實際手勢錄影並列 |

原本端到端 **≤150 ms** 互動目標繼續有效，另報 `INTERACTIVE-150`。即使本輪增量預算 PASS，若總時間仍超過150 ms，不能宣稱符合原互動目標或取消其 concern。P0 若顯示主要瓶頸在非筆刷階段，記錄數據與下一個有界修正；不重寫門檻遷就結果。

## 6. 前景操作、灰卡與獨立審查

### 6.1 操作矩陣

每個 case 記 app SHA／configuration、OS、輸入方式、操作步驟、畫面結果、磁碟／重開結果。首屏截圖只算 launch smoke。前景效能依原 UI spec 在相同裝置／fixture／build mode 至少各測 30 次操作；暖預覽 p95 不得比 B 惡化超過10%，並同時符合 PERF-UI heartbeat 限制。這組 UI 樣本獨立於 §5 的 render benchmark。

| ID | 平台／情境 | 必須觀察的結果 |
| --- | --- | --- |
| UI-MAC-01 | 原生數值欄位 Enter／blur／Escape、±、reset、非法值、同值外部更新 | 一次有效操作一筆 Undo；cancel/no-op 不保存；精確模型值不被顯示捨入改寫 |
| UI-MAC-02 | 滴管偏暖／冷／綠／洋紅、取消、切圖、晚到結果 | 正確方向；舊 frame 不提交；取消還原像素與 histogram |
| UI-BRUSH-01 | 新筆刷 paint／erase、切舊 brush、size／feather／flow、enable/select/delete | 手勢落點一致；一次 release 一次 history／保存；新舊選取不串線 |
| UI-BRUSH-02 | 繪製中換圖、geometry、snapshot、Undo／Redo、取消／close | 舊 release 不產生 stroke；新 frame 與 mapping 同 revision |
| UI-SIM-01 | 直／橫向、窄視窗、0.75×／1×／2× zoom、Files 開啟 | inspector／canvas 可操作；對應 source 落點與保存正確 |
| UI-DEVICE-01 | 真機觸控、方向切換、Split View、app-copy/in-place、外接來源離線再接回 | 原 RAW 不變；失敗不顯示 saved；重開 v5 edit 與 preview 相符 |
| UI-INPUT-01 | Pencil、外接鍵盤、VoiceOver 分列 | 筆畫／取消、焦點／Escape、標籤／值／44pt 操作目標；每種設備獨立結果 |
| STORE-01 | paint→export→close→reopen、Local off/on paste、batch／snapshot／刪最後快照 | v5 data／curation／snapshot／新舊 brush 保真；export 沒有少畫或重畫 |

主機鎖定或缺設備記 `NOT RUN`。基本真機觸控是原整合必要 gate；沒有 Pencil／鍵盤不冒充其支援已完成。安裝會替換現有 App 時，先確認相應部署已獲授權；授權前完成可建置可檢視的測試產物。

### 6.2 灰卡與色彩

有合格 RAW 灰卡才量測；固定可靠未裁切 ROI、同 recipe、同輸出色彩。使用原規格 `E = abs(log2(R/B)) + abs(log2(G/((R+B)/2)))`，四色偏各要求初始 E>0.01 且 E_after<E_before−1e-4。依上游 UI spec WB-02，白平衡後 D65 Lab 中 `sqrt(a*²+b*²) ≤ 3`；preview／export 經同一縮放及轉色流程對齊 ROI 後，平均 ΔE00≤1、第95百分位≤2。報告記錄白點、轉換、ROI 及測量流程，不能以平均 RGB 方向代替，轉色流程不可控時不得 PASS。缺素材仍 NOT RUN，不阻止先完成核心修正。

正式 Lightroom Gate 2 保持既有狀態，不是本 Native 候選 READY 的必要新增子項。任何校準或 Adobe renderer 啟用另案執行。

### 6.3 獨立審查

實作後由非 writer 以唯讀方式審查 Task 7 UI 與本次 renderer／取消／context 差異，至少涵蓋：source mapping、越界／extent、erase 順序、recipe 隔離、資料保存、晚到結果、thread isolation、allocation bounds、benchmark 可重現性。每個 finding 指向行為反例與測試。無 reviewer 時記 `NOT RUN`；writer 自查不標為獨立審查完成。可並行做不依賴此審查的 build／測試。

## 7. 分階段交付

| 階段 | 產物與範圍 | Exit gate |
| --- | --- | --- |
| P0 基線與量測 | 確定 TARGET base；提交 harness／生成器／oracle；Release/Debug B 原始數值；stage profiling | 能從乾淨 checkout 重現，無私人內容；不依賴暫存 probe |
| P1 取消與coverage | 先測進入長迴圈後取消及 scalar pixels，再做 tiles／bounded memory | CANCEL、coverage parity、geometry、validation、allocation regression PASS |
| P2 Context與產品接線 | 相同設定重用、不同 recipe 隔離、preview/export／scheduler 重跑 | recipe、色彩、stale-result、data contracts PASS |
| P3 效能驗收 | 執行 B/O ABBA、負載、匯出、50 次取消／切圖 | §5.3 每列有實測判定，150 ms 另列 |
| P4 操作與審查 | Mac/Simulator/真機、輸入、gray-card、獨立 reviewer | 每項有動作證據或明確 NOT RUN；finding 已修正與複驗 |
| P5 回歸與交接 | fresh full tests/builds、RAW、privacy/ZIP、CURRENT/report/handoff | status 依 §9，不以 partial 推導 READY |

相依順序：P0 → P1 → P2 → P3 → P5；P4 的環境／素材準備可在 P1 時進行，正式驗收必須針對最終產品 SHA。任何新產品修正後，重跑受影響測試與失效的產品產物驗收。

## 8. 目標檔案與驗證入口

| 路徑 | 工作 |
| --- | --- |
| `Sources/RawProcessingCore/Pipeline/BrushMaskRenderer.swift` | tiled coverage、bounded allocation、取消 |
| `Sources/RawProcessingCore/Pipeline/ImageRenderService.swift` | 相容設定 context 重用 |
| `Sources/RawProcessingCore/Pipeline/CancellableWork.swift` | 保留轉送；僅必要時補測或修正 |
| `Sources/RawProcessingCore/Preview/CoreImagePreviewRenderer.swift`、`PreviewScheduler.swift` | 分段觀測、正確接線與 stale rejection |
| `Sources/RawProcessingCore/Export/PhotoExporter.swift` | 共用 renderer、取消／暫存清理與原子發布 |
| `Tests/RawProcessingCoreTests/BrushMaskRendererTests.swift`、`BrushCoordinateMappingTests.swift`、`PreviewExportRecipeParityTests.swift` | scalar oracle 與獨立 pixel regression |
| 新 `BrushMaskCancellationTests.swift`、`BrushMaskPerformanceTests.swift` | stage barrier、worker 結束與效能數據 |
| 新 `Tests/LumaHarborIntegrationTests/BrushMaskPerformanceAcceptanceTests.swift` | RAW end-to-end、取消與export |
| 新 `Scripts/run-brush-performance-acceptance.sh` | Release B/O harness；機器可讀 sanitized結果 |
| `Sources/AdjustmentUI/BrushMaskOverlayView.swift`、`LocalAdjustmentsPanel.swift`；Mac/iPad canvas／toolbar | 僅修正驗收重現的相關 UI 缺陷 |
| 新 report、CURRENT、HANDOFF | 記錄狀態、commands、SHA、原始樣本與限制 |

實作時用全新 task scratch／derived-data；以下每條單獨記 exit code 與實際測試數，禁止零匹配／全 skipped 算 PASS：

```sh
swift test --scratch-path "$TASK_SWIFT_SCRATCH" --filter 'BrushMask|BrushCoordinate|PreviewExportRecipeParity|PreviewScheduler|RawRenderRecipe|DCPProfileFailClosed|SidecarV5|Snapshot|Curation|AdjustmentClipboard|EditorSessionSaveRace'
swift test --scratch-path "$TASK_SWIFT_SCRATCH"
swift build --scratch-path "$TASK_SWIFT_SCRATCH" -Xswiftc -strict-concurrency=complete
swift test -c release --scratch-path "$TASK_PERF_SCRATCH" --filter 'BrushMaskPerformanceAcceptanceTests'
swift test --scratch-path "$TASK_SWIFT_SCRATCH" --filter RawFixtureTests
Scripts/build-app-bundle.sh release
xcodebuild -project Apps/LumaHarborPad.xcodeproj -scheme LumaHarborPad -destination 'generic/platform=iOS Simulator' -derivedDataPath "$TASK_SIM_DATA" CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Apps/LumaHarborPad.xcodeproj -scheme LumaHarborPad -destination 'generic/platform=iOS' -derivedDataPath "$TASK_DEVICE_DATA" CODE_SIGNING_ALLOWED=NO build
Scripts/verify-release-privacy.sh build/LumaHarbor.app
Scripts/package-mac-release.sh release
git diff --check
```

先建立各 TASK 路徑；由 `LUMAHARBOR_SCRATCH_PATH` 指定 Mac scratch，`LUMAHARBOR_RELEASE_DIR` 指向全新未發布目錄。Release test 命令是套件入口，正式統計由 harness 先 build 再隔離執行，不把編譯時間納入。RAW 以 `LUMAHARBOR_RAW_FIXTURE_DIR` 私有注入。封裝後驗解壓內容、checksum、隱私；不覆寫已有 ZIP。`project.pbxproj` signing／版本設定必須無本次差異。

## 9. 完成判定、報告與回退

後續交付 `docs/testing/reports/2026-10-06-brush-performance-and-acceptance-repair.md`，逐列對照本 spec 及原整合 §12；每列標 PASS／FAIL／SKIPPED／NOT RUN，部分通過不能整列 PASS。附 exact commands、exit/counts、SHA、build configuration、bench generator version、每輪 raw samples、像素差、取消階段與 worker 結束、記憶體、UI 實際動作、review finding。

- **本輪程式修正驗收通過**：P0～P3 自動 gates、必要資料／recipe／像素／取消回歸、build/RAW/privacy 全通過且獨立審查無未處理阻擋 finding。
- **整合 READY**：在上述基礎上，原必要 Mac／Simulator／真機基本觸控、WB 灰卡與所有原規格必要 gate 完成；150 ms 目標仍未達時，保留 performance concern，不用增量預算 PASS 冒充。
- 任一必要 gate FAIL 或 NOT RUN：交付 `DONE_WITH_CONCERNS` 候選，明列實作已完成與驗收未完成的邊界。文件完成不代表產品 gate 通過。
- Lightroom Gate 2 維持獨立，不因上述狀態提升而改為 PASS。

保留修正前 baseline 與測試資料。出現像素、持久化、色彩或取消回歸時，停止發布該候選，依可審查提交回退本輪 renderer/context 改動；不得 destructive reset、刪 dirty files、降 sidecar v5、刪 brushMasks 或取消已合法保存的使用者編輯。回退後重跑對應 gate。

唯一下一步：在確認後續實作授權與 TARGET 基準後，先完成 P0 的可提交量測 harness、scalar oracle 與 Release baseline，再開始優化。
