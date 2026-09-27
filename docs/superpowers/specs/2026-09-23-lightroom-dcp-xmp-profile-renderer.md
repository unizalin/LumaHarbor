# Lightroom DCP／XMP Profile Renderer 與受控相容規格

**日期：** 2026-09-23
**狀態：** Draft，待 Luna 建立 TDD implementation plan
**分支：** `codex/lr-neutral-baseline-v1`
**基準 HEAD：** `fb421507bfeed1b2ff146109e3540d91de0eba62`
**執行者：** Luna，接手後為此 worktree 唯一 writer

## 1. 目的

本規格定義 LumaHarbor 下一階段的 clean-room DCP／XMP Camera Profile 相容層。目標是讓已支援的 camera／profile 組合，在 macOS 與 iPadOS 的 preview、export 使用同一份可驗證的 profile recipe，並改善 Lightroom Classic 與 LumaHarbor 對同一張 RAW 的 neutral baseline 與既有 XMP 風格檔結果差異。

本規格不是「完整複製 Lightroom」的宣告，也不允許先啟用未完成 renderer。正式 4/4 Gate 2、獨立 hold-out、效能、隱私與雙平台驗收全部通過前：

- Adobe renderer 維持 fail closed。
- production artifact registry 維持空白。
- feature flag 預設關閉。
- 使用者要求的 Adobe profile 名稱可保存，但有效渲染必須是 Native。
- 不得宣稱 Adobe Color、Adobe Standard 或 Lightroom 像素等價已完成。

## 2. 上位規格與目前證據

本規格是以下文件的後續獨立階段，不覆蓋既有 fail-closed 契約：

- `docs/superpowers/specs/2026-09-21-lightroom-gate2-production-hardening-and-reference-admission.md`
- `docs/superpowers/specs/2026-09-21-lightroom-gate2-calibration-and-controlled-enablement.md`
- `docs/superpowers/plans/2026-09-21-lightroom-gate2-calibration-and-controlled-enablement.md`
- `docs/testing/reports/2026-09-19-lightroom-neutral-raw-baseline-v1.md`
- `docs/coordination/2026-09-21-lr-gate2-production-hardening-handoff.md`

目前有效證據：

1. persisted Adobe policy 與 effective Native policy 的 fail-closed 路徑已具備測試基礎。
2. 現有 `CameraProfileFallback` 只有 3×3 matrix 與三條單調 1D channel LUT，無法表達完整 DCP 語意。
3. 現有 XMP Camera Profile 僅保存名稱，capability 是 `preserved`／`importOnly`，不代表已套用。
4. 正式 neutral 4/4 與獨立 hold-out 尚未通過。既有線性 Display P3 3×3 matrix 對 training 改善有限，且 hold-out clipping 退步。
5. 目前可接受狀態仍是 `READY ONLY WITH RENDERER DISABLED`。

本規格只在新的、隔離的 profile renderer 路徑擴充能力。它不回頭更改既有 Gate 2 的通過結果，也不把尚未通過的實驗結果寫成 production artifact。

## 3. 規範來源與授權邊界

### 3.1 規範來源

實作語意的優先順序：

1. Adobe DNG Specification 1.7.1 與官方 DNG SDK／Profiles SDK 文件。
2. Adobe Camera Raw XMP namespace 公開文件。
3. LumaHarbor 自有 fixture、Lightroom Classic 輸出與既有 Gate 2 驗收資料。
4. 開源專案只能作為行為交叉驗證與測試 oracle。

官方參考：

- <https://helpx.adobe.com/camera-raw/desktop/dng-and-file-formats/digital-negative.html>
- <https://developer.adobe.com/xmp/docs/xmp-namespaces/crs/>

### 3.2 開源參考政策

- LightTable Digital Darkroom、RawTherapee：GPL-3.0，只能觀察行為、資料順序、插值邊界與測試案例，不得複製程式碼、常數表或衍生實作。
- mini-film：MIT，可用來理解 `crs:RGBTable` container 與 delta reconstruction；若實際採用任何程式片段，必須保留授權與 attribution，並由 reviewer 逐行確認來源。
- dng-channel-tool：MIT，只能作為 TIFF／DNG tag 的次要交叉檢查來源。
- Brightroom、AwayPhotoRawEditor：只供 Swift／Core Image／非破壞編輯架構參考，不作為 RAW、DCP 或 Lightroom 像素相容證據。
- `lightroom-adobe-get-trial` 與授權繞過無關本功能，不得引入、執行或參考。

### 3.3 禁止納入 Git 的資料

下列資料不得加入 Git、測試快照、JSON 報告或註解：

- 私人 RAW、XMP、DCP、TIFF、JPEG 或 preview。
- 私人素材的 hash、檔名、相機序號、拍攝資訊與絕對路徑。
- Adobe proprietary profile payload、table 或反編譯結果。
- Lightroom catalog、登入資訊、授權資訊或快取。

可提交的 fixture 必須是專案自行產生、可散布、去識別的 synthetic DCP／XMP／TIFF fixture，並在 fixture README 記錄生成方式與授權。

## 4. 名詞與狀態模型

- `requestedProfile`：使用者或 XMP 要求的 profile 名稱與相機範圍。
- `persistedPolicy`：文件、sidecar 或 catalog 保存的渲染政策。
- `effectivePolicy`：經 feature flag、artifact admission、camera match 與 runtime validation 後實際使用的政策。
- `profileDocument`：經嚴格 bounds check 後解析出的 DCP 純值模型。
- `admittedArtifact`：已通過 manifest、camera／profile scope、Gate 2 與 production admission 的版本化 artifact。
- `Native`：目前 LumaHarbor 原生 Core Image RAW pipeline，為所有失敗狀態的唯一 fallback。
- `DCP profile tables`：HueSatMap、LookTable、ProfileToneCurve 等 DCP profile 內容。
- `XMP RGBTable`：XMP 內嵌的 creative table。其 stage、編碼與適用條件必須獨立驗證，不能假設等同 DCP LookTable。

## 5. 功能範圍

### 5.1 納入

1. Bounds-checked TIFF／DCP parser，支援本規格明列的 tag。
2. `ColorMatrix1/2`、`ForwardMatrix1/2`、`CalibrationIlluminant1/2` 與雙光源插值。
3. `ProfileHueSatMapDims`、HueSatMap data／encoding 與三線性插值。
4. `ProfileLookTableDims`、LookTable data／encoding 與三線性插值。
5. `ProfileToneCurve` 的單調驗證、插值與 hue-preserving 應用。
6. `BaselineExposureOffset` 與 `DefaultBlackRender` 的規格語意。
7. XMP `CameraProfile` request 的 profile resolution。
8. XMP `RGBTable` 的安全 decoder、純值模型與隔離測試。渲染 stage 未被正式證明前維持 parse-only／disabled。
9. 原子性 profile renderer、版本化 recipe、preview／export parity。
10. synthetic fixtures、process-level CLI tests、sanitized report 與 Mac／iPad 驗收。

### 5.2 不納入

- 複製 Adobe 或 GPL 專案的 renderer 實作。
- 內建 Adobe proprietary DCP、LUT 或相機專屬 payload。
- 以 Exposure slider、Basic tone、Presence、Curve、Detail 或單張照片特例補償差異。
- 以 camera-wide 常數掩蓋 profile stage 或解碼錯誤。
- 一次宣告所有相機、所有 Adobe profile、所有 Process Version 都相容。
- iPad Inspector、桌面側欄或一般編輯 UI 的重新設計。
- 自動下載第三方 profile、繞過 Lightroom／Adobe 授權或讀取 Lightroom 私有資料庫。

`BaselineExposureOffset` 是 DCP 文件中的 profile metadata stage，不是使用者 Exposure slider。它只能依 profile 明確資料套用，不得由照片內容、training 結果或人工觀感調整。

## 6. 建議模組邊界

Luna 建立 implementation plan 時必須先核對現有 package ownership，再以最小依賴安排下列檔案。若實際路徑不同，plan 必須說明原因。

### 6.1 新增檔案

- `Sources/RawProcessingCore/Profile/DCPProfileDocument.swift`
- `Sources/RawProcessingCore/Profile/DCPProfileParser.swift`
- `Sources/RawProcessingCore/Profile/DCPProfileMatrixResolver.swift`
- `Sources/RawProcessingCore/Profile/DCPHueSatMap.swift`
- `Sources/RawProcessingCore/Profile/DCPLookTable.swift`
- `Sources/RawProcessingCore/Profile/DCPProfileToneCurve.swift`
- `Sources/RawProcessingCore/Profile/DCPProfileRenderer.swift`
- `Sources/RawProcessingCore/Profile/DCPProfileArtifactV2.swift`
- `Sources/PresetCore/XMP/AdobeRGBTable.swift`
- `Sources/PresetCore/XMP/AdobeRGBTableCodec.swift`

對應測試：

- `Tests/RawProcessingCoreTests/DCPProfileParserTests.swift`
- `Tests/RawProcessingCoreTests/DCPProfileMatrixResolverTests.swift`
- `Tests/RawProcessingCoreTests/DCPHueSatMapTests.swift`
- `Tests/RawProcessingCoreTests/DCPLookTableTests.swift`
- `Tests/RawProcessingCoreTests/DCPProfileToneCurveTests.swift`
- `Tests/RawProcessingCoreTests/DCPProfileRendererTests.swift`
- `Tests/RawProcessingCoreTests/DCPProfileFailClosedTests.swift`
- `Tests/PresetCoreTests/AdobeRGBTableCodecTests.swift`

### 6.2 預期修改檔案

- `Sources/RawProcessingCore/Decoding/RawRenderRecipe.swift`
- `Sources/RawProcessingCore/Decoding/RawRenderRecipeResolver.swift`
- `Sources/RawProcessingCore/Pipeline/AdjustmentPipeline.swift`
- `Sources/RawProcessingCore/Pipeline/ImageRenderService.swift`
- `Sources/PresetCore/XMP/XMPFeatureCapability.swift`
- `Sources/PresetCore/XMP/XMPImportExport.swift`
- `Sources/RawProcessingCore/Profile/Generated/ProfileCalibrationArtifactManifestsV1.swift`

現有 `CameraProfileFallback` v1 與 fail-closed tests 不得移除或改寫成自動啟用 v2。v2 必須是新的 artifact kind／version，registry 也必須分開。

## 7. Parser 與安全契約

DCP parser 必須是 Foundation／Swift 的 bounds-checked clean-room 實作，或使用已存在且授權相容的系統 API。不得依賴外部 CLI 作 production runtime。

最低安全條件：

1. 支援 little-endian／big-endian TIFF header，拒絕無效 magic、offset、type、count 與 cycle。
2. 所有 `offset + length`、dimension product、byte count 都使用 overflow-checked arithmetic。
3. 單一 DCP 最大 64 MiB；IFD entry 最大 4,096；table triplet 最大 4,194,304。
4. string 最大 1,024 bytes；所有 floating-point 值必須 finite。
5. matrix 維度必須精確，不能自動截斷或補零。
6. HueSatMap／LookTable payload 長度必須與 dimensions 完全一致。
7. ProfileToneCurve x 值必須單調遞增、domain 合法；重複或反向 knot 必須拒絕。
8. XMP RGBTable 必須驗證 base85、zlib、header、版本、維度、uncompressed size 與 delta reconstruction；禁止 zip bomb 與超額記憶體配置。
9. 未支援 tag 可保存為 diagnostics，但不得造成部分套用。
10. malformed、unsupported 或資源超限一律回傳 typed error，由 resolver fail closed。

Parser 必須有 synthetic valid fixtures、truncated payload、bad offset、integer overflow、NaN／Infinity、oversized dimensions、invalid curve 與 decompression bomb 的 RED／GREEN 測試。

## 8. 渲染語意

### 8.1 Decoder／camera color stage

1. 由 RAW metadata 與 As Shot white balance 推導 renderer 需要的 camera neutral／CCT 資訊。
2. 依 `CalibrationIlluminant1/2` 使用 reciprocal temperature space 做雙光源插值。
3. 有合法 `ForwardMatrix` 時優先使用；否則使用 `ColorMatrix` 與明確的 D50 chromatic adaptation。
4. 結果進入版本化 linear working space，不可依目前螢幕 profile 改變。
5. 任一必要資訊缺失、matrix singular、camera model 不符或轉換不 finite，整個 profile stage 失敗並回到 Native。

### 8.2 DCP profile stage

profile stage 的順序必須以 DNG 規格與官方 SDK 驗證，並在 plan 中鎖定：

1. HueSatMap，包含 table encoding 與雙光源插值。
2. 規格定義的 `BaselineExposureOffset`／`DefaultBlackRender`。
3. LookTable，包含 table encoding。
4. hue-preserving ProfileToneCurve。

Hue interpolation 必須走最短圓周路徑。table storage order、domain clamp、value extrapolation 與 encoding 必須各自有 isolation tests，不能只靠端到端圖片看起來接近。

### 8.3 XMP RGBTable stage

第一階段只允許 decode、round-trip、dimension validation 與 synthetic table sampling。只有在以下條件全部具備後才可接入實際 renderer：

- 公開文件或可重複的 Lightroom probe 證明 stage order。
- 1D／3D table interpolation 與 neutral ramp 的 isolation tests 通過。
- 同一 RAW 的 training 與獨立 hold-out 都改善。
- 不會重複套用 DCP LookTable 或現有 XMP effects。

若 stage order 未證明，capability 必須保持 `preserved`／`importOnly`，不得因 parser 已完成就標示 applied。

## 9. 原子性 fail-closed 契約

Profile renderer 是原子操作，不允許 matrix 已套用、LookTable 失敗後繼續輸出 hybrid image。

下列任一條件成立時，必須得到和 persisted `.native` 完全一致的 decoder options、工作／輸出色域、camera profile stage、recipe、尺寸與 pixel digest：

- feature flag 關閉。
- production registry 無匹配 artifact。
- camera model、profile name、artifact version 或 manifest 不符。
- DCP／RGBTable 解析或 validation 失敗。
- 任一 renderer stage runtime error。
- recipe 來自舊版本且缺少必要的 effective policy／artifact identity。
- Undo、Reset、copy/paste、batch export 或 app restart 未取得明確 admission。

同時必須保留：

- `persistedPolicy == .adobeProcess2012V1`。
- 原始 `requestedProfile` 名稱。
- `effectivePolicy == .native`。
- 可供 UI 顯示的「Profile 已保存、未套用」diagnostic。

不得以 `try? ... ?? partiallyRenderedImage` 隱藏 profile stage 錯誤。Resolver 必須在 render 前產生完整有效 recipe；若 runtime 仍失敗，必須以完整 Native recipe 重跑或回報失敗，不能回傳部分套用結果。

## 10. Artifact 與 controlled enablement

新 artifact 必須是可序列化、可驗證、與來源檔案無關的純值：

- schema／renderer version。
- camera make／model scope。
- profile identity 與 process version scope。
- 已正規化的 matrices、tables、tone curve 與 metadata。
- 產物本身的 deterministic digest。
- training／hold-out evidence ID，但不得包含私人檔名、路徑或 source hash。

Admission 必須同時滿足：

1. exact camera + profile scope match。
2. artifact validation PASS。
3. 正式 neutral 4/4 Gate 2 PASS。
4. 獨立 hold-out PASS，且 clipping 不退步。
5. preview／export 與 Mac／iPad parity PASS。
6. 效能與記憶體 budget PASS。
7. privacy scan PASS。
8. production registry 的明確人工 admission change。

在 admission 前，generated production registry 必須保持空白。測試可使用 dependency-injected test registry，不得共用 production registry。

## 11. TDD 執行階段

Luna 必須先建立：

`docs/superpowers/plans/2026-09-23-lightroom-dcp-xmp-profile-renderer.md`

計畫需逐 task 列出精確檔案、RED 測試、最小實作、GREEN 指令、停止條件與不得觸碰範圍。建議順序如下。

### P0：證據與 ownership freeze

- 核對 branch、HEAD、51 個既有 dirty paths 與 coordination 文件。
- 接手後 Luna 是此 worktree 唯一 writer；Codex／其他 agent 僅 review。
- 先建立 source／license inventory 與 evidence map，不修改產品程式碼。
- 若 dirty state 與 `CURRENT.md` 不符，停止並回報。

### P1：DCP container parser

- 先做 synthetic TIFF／DCP writer for tests。
- 以 malformed／overflow／endianness RED tests 驅動 parser。
- 此階段不得接入 renderer、resolver 或 registry。

### P2：Matrix 與 illuminant resolver

- 以 identity、single illuminant、dual illuminant、shortest-path／D50 adaptation 的小型向量測試驗證。
- 與至少兩個獨立 oracle 的 stage output 比較，不使用真實私人檔案做 committed fixture。

### P3：HueSatMap 與 LookTable

- 分開測 storage order、clamp、encoding、interpolation、hue wrap 與 dual illuminant blend。
- 先純函式、後 tile／image buffer；不得直接修改 app pipeline。

### P4：ProfileToneCurve 與 profile metadata

- 驗證 monotonic curve、hue preservation、identity no-op、BaselineExposureOffset 與 DefaultBlackRender。
- 禁止把 profile metadata 映射成可編輯 Exposure slider 或 dirty edit。

### P5：XMP RGBTable

- 先完成安全 codec、neutral reconstruction 與 synthetic 1D／3D sampling。
- stage order 未有證據前保持 parse-only，不進 production pipeline。

### P6：原子 renderer 與 recipe resolver

- 新 v2 artifact、test-only registry、feature flag 與 exact scope match。
- 完成 Native digest parity、persistence、rollback、Undo／Reset、copy/paste、batch export tests。
- 任何 stage 失敗都測到完整 Native fallback，禁止 hybrid output。

### P7：Reference comparator 與 cross-oracle

- 使用現有 16-bit encoded sRGB loader、metadata validator、clipping metrics v2、`--all-neutral` 與 sanitized JSON。
- 加入 process-level CLI tests，不以 source-string contract test 代替。
- 私人 corpus 只從環境變數讀取，報告不可洩漏識別資訊。

### P8：Production admission 與雙平台驗收

- 正式 4/4 neutral、獨立 hold-out、profile effect、preview／export parity。
- 完整 `swift test`、strict-concurrency build、macOS app bundle、iPad generic Simulator build。
- 實體 iPad 安裝與真實 RAW／XMP 驗收。
- 只有全部通過後才提出 registry admission patch；不得在同一 task 自動啟用。

每個 phase 若達停止條件，必須保留現有 fail-closed 路徑並回報 `NOT ADMITTED`，不可跳過失敗繼續接 production renderer。

## 12. 驗收標準

### 12.1 單元與安全

- 每個 parser／math／table stage 都有 identity、boundary、malformed 與 deterministic tests。
- synthetic DCP round-trip 可重現，無平台浮點漂移造成的非決定結果。
- fuzzer／malformed corpus 不 crash、不越界、不無限配置。
- disabled／unsupported／error path 的 decode、preview、export pixel SHA256 與 Native 完全一致。

### 12.2 Stage oracle

- matrix、HueSatMap、LookTable、tone curve 各自和公開規格或獨立 oracle 比對。
- oracle 比較使用小型 synthetic vector，不以完整圖片平均值掩蓋單一 stage 錯誤。
- GPL 專案只輸出行為結果，不將其程式碼、fixture payload 或 generated source 納入 repo。

### 12.3 Gate 2 與 hold-out

- 四組互不重複、原尺寸、16-bit encoded sRGB Lightroom／LumaHarbor paired TIFF 全數通過現有 thresholds v2。
- training 與 hold-out 相機／照片範圍事先凍結；hold-out 不得參與係數選擇。
- mean、p95、SSIM 與 clipping 全部通過；任一指標失敗即不 admission。
- XMP profile effect 與 final comparison 分開報告，不能用 final 圖抵銷 neutral baseline 差異。

### 12.4 雙平台與效能

- macOS preview／export 使用相同 recipe、artifact identity、output space 與尺寸規則。
- iPadOS preview／export 與 macOS 的有效政策、recipe、尺寸與像素 digest 一致。
- 現有 full-resolution 記憶體上限不退步，且 profile renderer 的 P95 時間不得比 Native baseline 增加超過 15%，除非先更新效能規格並取得批准。
- 實體 iPad 未執行時必須標示 `NOT RUN`，不得以 Simulator 代替。

### 12.5 最終命令

至少執行並記錄：

```bash
swift test --filter DCPProfileParserTests
swift test --filter DCPProfileMatrixResolverTests
swift test --filter DCPProfileRendererTests
swift test --filter DCPProfileFailClosedTests
swift test --filter AdobeRGBTableCodecTests
swift test
swift build -Xswiftc -strict-concurrency=complete
Scripts/build-app-bundle.sh debug
xcodebuild -project Apps/LumaHarborPad.xcodeproj -scheme LumaHarborPad -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
git diff --check
```

另需執行既有 reference validator、`--all-neutral` comparator、privacy／absolute-path scan，並在報告列出實際 executed、skipped、failed 數量。

## 13. 不得觸碰範圍

除非某 task 的 RED 測試證明必要，Luna 不得修改：

- Editor UI、iPad Inspector layout、library／catalog UI。
- Basic tone、Presence、Curve、Detail、Grain 與局部調整 renderer。
- 既有 Native decoder 預設行為。
- 現有 v1 artifact 或其歷史測試證據。
- `main`、其他 branch／worktree、Git history。
- 私人 fixture 內容、檔名或目錄配置。

本輪不得 commit、push、merge、rebase、修改 main 或清理既有 dirty files，除非使用者之後明確授權。

## 14. Luna 交付內容

Luna 的第一個交付不是一次寫完 renderer，而是：

1. 讀完 `AGENTS.md`、coordination、上位 spec／plan／report 與本規格。
2. 核對 worktree dirty state，確認不覆蓋既有 51 個 dirty paths。
3. 建立逐 task TDD implementation plan。
4. 先執行 P0，再從 P1 parser 開始，小步 RED／GREEN。
5. 每個 phase 回報修改檔案、測試數、skip、failure、停止條件與剩餘風險。
6. 在 P8 全部通過前，持續回報 `READY ONLY WITH RENDERER DISABLED`。

任何「看起來更像 Lightroom」都不能取代數值證據、hold-out、雙平台 parity 與 fail-closed safety。
