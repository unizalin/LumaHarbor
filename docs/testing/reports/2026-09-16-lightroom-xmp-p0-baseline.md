# Lightroom XMP P0 基線驗收報告

日期：2026-09-16
分支：`codex/lightroom-xmp-visual-parity-spec`

## 結果

P0 基線完成。這一輪建立能力清單、私有 fixture 注入、參照矩陣契約、純值效果差異指標，以及 macOS 參照比較命令；沒有改變既有照片渲染順序、調整值或 XMP 套用語意。

能力清單目前涵蓋 10 個啟用中的 feature／compatibility capability、55 個 namespace-qualified Camera Raw property ID，並保留 `native`、`approximate`、`preserved`、`rejected` 的後續擴充邊界。未知 RDF 與未支援欄位仍走既有 preservation 路徑。

## 變更

- `PresetCore` 新增 `XMPCapabilityManifest`，由現有 mapping registry 衍生，並補上 tone curve 的複合 property ownership。
- 測試只從 `LUMAHARBOR_LR_XMP_FIXTURE_DIR` 注入私人 XMP；報告只使用 `fixture-01` 等去識別化 ID。
- 新增五案例 reference matrix template 與 validator；矩陣只存穩定 ID、色彩空間、位元深度與尺寸欄位，不存私人檔名或影像內容。
- `RawProcessingCore` 新增相對效果的 mean／p95 RGB error 與固定 11×11 luminance SSIM。
- 新增 `LumaHarborReferenceCompare` macOS 診斷命令，使用 ImageIO 載入 TIFF／PNG／JPEG，輸出不含路徑的 JSON。

## 驗證證據

- 聚焦測試：12 executed、1 skipped、0 failures；skip 是未設定私人 corpus 時的明確 `XCTSkip`。
- 私有 corpus 注入驗證：5/5 fixture 載入與 preview PASS；輸出已去識別化，未寫入來源路徑或原始內容。
- 參照矩陣 validator：`PASS reference matrix schema=1 cases=5 images=20`。
- strict-concurrency build：PASS。
- 完整 strict-concurrency `swift test`：2348 executed、10 skipped、0 failures。
- `LumaHarborReferenceCompare --help`：PASS；缺少參照圖時輸出 `NOT RUN` 並以非零狀態結束。
- `git diff --check`：PASS。

## 尚未執行

- Lightroom／Adobe Camera Raw 實際 neutral／preset 參照影像尚未匯出，因此五案例的像素效果比較、人工目視與 Adobe smoke test 為 `NOT RUN`。
- 真機 iPad 直向／橫向與 macOS 多尺寸的人工視覺驗收不屬於這個純資料 P0，仍維持 `NOT RUN`。

## 下一步

先依 `docs/testing/lightroom-xmp-reference-matrix.md` 產生五案例的 Lightroom neutral／preset 參照輸出，再進入 P1：把 capability level 與 reference metrics 接到 importer／renderer 的可觀測驗收，不先宣稱逐像素等同 Adobe。
