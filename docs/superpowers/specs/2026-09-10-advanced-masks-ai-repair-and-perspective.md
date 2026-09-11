# P5: Advanced Masks, On-Device AI Segmentation, Repair and Perspective Spec

- 狀態：實作中（P5）
- 日期：2026-09-11
- 依賴：P0-P4（全部通過）
- 依據：`docs/superpowers/specs/2026-09-10-professional-editing-completion-design.md` §6.5、§6.7、§7、§8、§11.2

## 1. 範圍與目標

P5 補齊 LumaHarbor 的專業遮罩、裝置端 AI 主體/背景分割、修復（Spot Heal/Clone/Red-eye）與四角透視校正（Perspective Corner Pins）：

1. **進階遮罩（Advanced Masks）**：
   - 擴充 `LocalAdjustmentKind`：`linearGradient`、`radialGradient`、`brush`、`luminanceRange`、`colorRange`、`subject`、`background`、`spotHeal`。
   - 遮罩共同屬性：名稱（`name`）、啟用/停用（`isEnabled`）、反轉（`isInverted`）、不透明度（`opacity` 0...100）、feather。
   - Radial Gradient：位置（x, y）、半徑（radius, radiusY / aspectRatio）、旋轉角度（angleDegrees）、feather。
   - Brush：筆刷筆觸集合 `[BrushStroke]`，包含 points `[BrushPoint]` (x, y, pressure)、radius、feather。
   - Range Masks：
     - `luminanceRange`：指定亮度區間 `[luminanceMin, luminanceMax]` (0...1) 與 feather。
     - `colorRange`：指定目標色相（`colorTargetHue` 0...360）與色相容許度（`colorHueTolerance` 0...180）與 feather。
   - On-device AI Masks (`subject`, `background`)：
     - 使用 Apple Vision 框架在裝置端本機推論（`VNGenerateForegroundInstanceMaskRequest` 或安全 fallback）。
     - 照片與遮罩絕不上傳、不送出網路、不記錄私人路徑。
     - 遮罩結果以 8-bit grayscale PNG 儲存在 `.lumaharbor/masks/<photo-id>/<mask-id>.png`。
     - Sidecar 保存相對路徑、`sourceFingerprint`、`maskDigest`（SHA-256）、`visionRevision` 與 `reconstructionNeeded` 標記。
     - 具備離線/無 Vision 支援時的健全 fallback 機制。
2. **修復強化（Repair / Heal / Clone / Red-Eye）**：
   - `SpotHealMode`：`heal`、`clone`、`redEye`。
   - `redEye`：指定目標瞳孔半徑與消除紅眼效果。
3. **四角透視（Perspective Corner Pins）**：
   - 在 `GeometryAdjustments` 新增 `cornerPins: PerspectiveCornerPins?`，定義 normalized 頂點（topLeft, topRight, bottomRight, bottomLeft）。
   - 在 `GeometryRenderer` 結合 `CIPerspectiveTransform` 進行校正。
4. **iPad Inspector 面板補齊（P4 Handoff 遺留確認事項）**：
   - 在 `PadEditorView.swift` 的 `PadInspectorHost` 中，補齊 P4 的 `RenderingProfilePanel`、`PresenceAdjustmentPanel` 與 `ColorGradingAdjustmentPanel` 掛載，使 iPad 與 Mac 功能完全對齊。
5. **UI & 本地化**：
   - `LocalAdjustmentsPanel` 支援遮罩新增、列表、重新命名、反轉、不透明度、刪除、複製。
   - 8 國語言在地化 key parity 與非英文 fallback。

## 2. 資料模型契約

### 2.1 `LocalAdjustmentKind`
```swift
public enum LocalAdjustmentKind: String, Codable, Equatable, Hashable, Sendable {
    case linearGradient
    case radialGradient
    case brush
    case luminanceRange
    case colorRange
    case subject
    case background
    case spotHeal
}
```

### 2.2 `LocalAdjustment`
```swift
public struct LocalAdjustment: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var kind: LocalAdjustmentKind
    public var isEnabled: Bool
    public var name: String
    public var opacity: Double // 0...100, default 100
    public var isInverted: Bool // default false
    public var geometry: LocalAdjustmentGeometry
    public var adjustments: LocalAdjustmentPatch
}
```

### 2.3 `LocalAdjustmentGeometry` 擴充
```swift
public struct LocalAdjustmentGeometry: Codable, Equatable, Hashable, Sendable {
    // 既有欄位保持相容：x, y, angleDegrees, range, sourceX, sourceY, radius, feather, healMode
    // 新增：
    public var radialRadiusY: Double?
    public var brushStrokes: [BrushStroke]
    public var luminanceMin: Double?
    public var luminanceMax: Double?
    public var colorTargetHue: Double?
    public var colorHueTolerance: Double?
    public var maskRelativePath: String?
    public var sourceFingerprint: String?
    public var maskDigest: String?
    public var visionRevision: Int?
    public var reconstructionNeeded: Bool
    public var redEyePupilRadius: Double?
}
```

### 2.4 四角透視 `PerspectiveCornerPins`
```swift
public struct PerspectiveCornerPins: Codable, Equatable, Hashable, Sendable {
    public var topLeft: NormalizedPoint
    public var topRight: NormalizedPoint
    public var bottomRight: NormalizedPoint
    public var bottomLeft: NormalizedPoint
    public static let standard: PerspectiveCornerPins
    public var isIdentity: Bool
}
```

## 3. 渲染順序與演算法
按照設計規格 §8：
1. Geometry: Orientation -> Straighten -> Perspective (Keystone / Corner Pins) -> Crop.
2. Local Adjustments:
   - 每個 Mask 先計算其灰階遮罩 (0...1)。
   - 若 `isInverted` 為 true，反轉遮罩 (1 - mask)。
   - 若 `opacity < 100`，縮放遮罩 (mask * opacity / 100)。
   - 透過 `CIBlendWithMask` 與 `LocalAdjustmentPatchRenderer.apply` 進行合成。
   - Repair（Heal / Clone / Red-Eye）依序進行。

## 4. 驗證契約
- 完整 `swift test` 必須全數通過，不得有 regression。
- 8 語系在地化 parity 測試通過。
- Strict concurrency build 通過。
- iPad Simulator build 通過。
- 隱私掃描（無個人路徑、帳號、憑證）通過。
