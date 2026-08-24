# iPad RAW Editing Vertical Slice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 M1 以上 iPad 建立可安裝的 LumaHarbor 垂直版本，能從 Files／外接 SSD 原地開啟一張 RAW，或複製到 App 儲存，使用既有十個基本調整並以 sidecar 非破壞性保存。

**Architecture:** 將現有 `EditorViewModel` 的平台中立狀態與排程抽到 `EditorCore.EditorSession`，將十個基本滑桿抽到 `AdjustmentUI.BasicAdjustmentPanel`。macOS shell 繼續使用現有圖庫與 AppKit；iPad shell 透過 `PhotoDocumentStore` 建立單張照片工作階段，使用 Swift Playgrounds／Xcode 可部署的 `.swiftpm` iOS application package。

**Tech Stack:** Swift 5.9、SwiftUI、Combine、Core Image、CryptoKit、Swift Package Manager、AppleProductTypes iOS application package、XCTest、Xcode 26.6；不新增第三方 dependency。

## Global Constraints

- 基準版本為 `a78752e`；實作從已提交設計 `docs/superpowers/specs/2026-08-24-cross-platform-adjustments-design.md` 開始。
- macOS 最低版本維持 14；iPadOS 最低版本為 17；iPad 硬體最低為 M1。
- RAW 原檔永遠不可改寫；成品及 sidecar 都必須寫成其他檔案。
- 原地開啟為預設；使用者也可明確選擇複製到 App 儲存。
- 所有照片處理完全在裝置上執行，不上傳照片、預覽或特徵。
- Mac 與 iPad 共用 `PhotoAdjustments`、渲染順序、Preset/XMP 型別及 `EditorSession`。
- 本計畫不交付完整多照片圖庫、跨裝置寫入租約、完整 Preset browser、XMP 檔案 UI 或批次匯出；這些各自建立後續計畫。
- 不把 `SKIPPED` 當 `PASS`；測試報告與 log 不得包含私人絕對路徑。
- 不修改或清理 `docs/reference/`，也不覆蓋其他代理未提交的變更。

## File Structure

### 新增 targets

- `Sources/EditorCore/EditorDependencies.swift`：編輯工作階段所需的 preview／load／save dependency contract。
- `Sources/EditorCore/EditorAlert.swift`：跨平台、可呈現但不含 AppKit/UIKit 的錯誤資料。
- `Sources/EditorCore/EditorSession.swift`：目前照片、調整、Undo、預覽、autosave 與 transient Preset preview。
- `Sources/AdjustmentUI/BasicAdjustmentPanel.swift`：Mac／iPad 共用的十個基本滑桿。
- `Tests/EditorCoreTests/EditorSessionEditingTests.swift`：跨平台編輯狀態與保存契約。
- `Tests/AdjustmentUITests/BasicAdjustmentPanelModelTests.swift`：十個控制項的來源、順序及格式。

### 單張照片文件

- `Sources/PhotoLibraryCore/Documents/PhotoDocument.swift`：原地／App 副本的身份、來源連結和工作 URL。
- `Sources/PhotoLibraryCore/Documents/PhotoDocumentStore.swift`：原地開啟、驗證後複製、document record 與 sidecar 儲存。
- `Tests/PhotoLibraryCoreTests/PhotoDocumentStoreTests.swift`：不改原檔、copy-verify-commit、重開與失敗清理。

### iPad application package

- `Apps/LumaHarborPad.swiftpm/Package.swift`：可由 Xcode 直接建置及部署的 iPad App product。
- `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/LumaHarborPadApp.swift`：iPad `@main` 與 dependency composition。
- `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadRootView.swift`：Files importer、來源模式選擇與錯誤呈現。
- `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorModel.swift`：把 `PhotoDocumentStore` 接到 `EditorSession`。
- `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorView.swift`：畫布、橫向右欄、直向抽屜與專注模式。

### 現有檔案

- `Package.swift`：加入 iOS platform、`EditorCore`、`AdjustmentUI` 及 test targets。
- `Sources/LumaHarborApp/AppServices.swift`：產生 `EditorDependencies`，保留 macOS composition root。
- `Sources/LumaHarborApp/ViewModels/LibraryViewModel.swift`：改用 `EditorSession`。
- `Sources/LumaHarborApp/Views/InspectorView.swift`：使用共用 `BasicAdjustmentPanel`。
- `Tests/LumaHarborAppTests/AppTestSupport.swift`：建立 `EditorDependencies` 的測試 graph。
- `Scripts/run-ipad-vertical-slice-acceptance.zsh`：macOS regression、iOS Simulator build 與報告輸出。

---

### Task 1: 建立跨平台 target 邊界與 iOS 編譯 gate

**Files:**
- Modify: `Package.swift`
- Modify: `Sources/PhotoLibraryCore/Access/SecurityScopedBookmark.swift`
- Modify: `Plugins/CompileMetalKernels/CompileMetalKernels.swift`
- Create: `Sources/EditorCore/EditorDependencies.swift`
- Create: `Sources/EditorCore/EditorAlert.swift`
- Create: `Sources/AdjustmentUI/BasicAdjustmentPanelModel.swift`
- Create: `Tests/EditorCoreTests/EditorDependenciesTests.swift`
- Create: `Tests/AdjustmentUITests/BasicAdjustmentPanelModelTests.swift`

**Interfaces:**
- Consumes: `PhotoAsset`、`PhotoAdjustments`、`PreviewScheduler`、`PreviewRendering`。
- Produces: `EditorDependencies`、`EditorAlert`、`BasicAdjustmentPanelModel.rows`。

- [ ] **Step 1: 寫出 target contract 的失敗測試**

```swift
// Tests/EditorCoreTests/EditorDependenciesTests.swift
import XCTest
@testable import EditorCore

final class EditorDependenciesTests: XCTestCase {
    func testEditorAlertKeepsActionableCopySeparate() {
        let alert = EditorAlert(title: "Open failed", message: "Unreadable", nextStep: "Choose another file")
        XCTAssertEqual(alert.title, "Open failed")
        XCTAssertEqual(alert.message, "Unreadable")
        XCTAssertEqual(alert.nextStep, "Choose another file")
    }
}
```

```swift
// Tests/AdjustmentUITests/BasicAdjustmentPanelModelTests.swift
import XCTest
@testable import AdjustmentUI

final class BasicAdjustmentPanelModelTests: XCTestCase {
    func testRowsComeFromTheCanonicalAdjustmentCatalog() {
        XCTAssertEqual(BasicAdjustmentPanelModel.rows.count, 10)
        XCTAssertEqual(Set(BasicAdjustmentPanelModel.rows.map(\.kind.rawValue)).count, 10)
    }
}
```

- [ ] **Step 2: 執行測試並確認 target 尚不存在**

Run: `swift test --filter 'EditorDependenciesTests|BasicAdjustmentPanelModelTests'`

Expected: FAIL，訊息包含 `no such module 'EditorCore'` 或找不到 target。

- [ ] **Step 3: 在 Package.swift 加入平台與 targets**

```swift
platforms: [
    .macOS(.v14),
    .iOS(.v17)
],
products: [
    .executable(name: "LumaHarbor", targets: ["LumaHarbor"]),
    .library(name: "PhotoLibraryCore", targets: ["PhotoLibraryCore"]),
    .library(name: "RawProcessingCore", targets: ["RawProcessingCore"]),
    .library(name: "PresetCore", targets: ["PresetCore"]),
    .library(name: "EditorCore", targets: ["EditorCore"]),
    .library(name: "AdjustmentUI", targets: ["AdjustmentUI"])
]
```

在 `PresetCore`／`PhotoLibraryCore` 後加入：

```swift
.target(
    name: "EditorCore",
    dependencies: ["PhotoLibraryCore", "RawProcessingCore", "PresetCore", "Localization"]
),
.target(
    name: "AdjustmentUI",
    dependencies: ["EditorCore", "RawProcessingCore", "Localization"]
),
```

在 test targets 加入：

```swift
.testTarget(name: "EditorCoreTests", dependencies: ["EditorCore"]),
.testTarget(name: "AdjustmentUITests", dependencies: ["AdjustmentUI", "EditorCore", "RawProcessingCore"]),
```

- [ ] **Step 4: 實作最小公開 contract**

```swift
// Sources/EditorCore/EditorAlert.swift
import Foundation

public struct EditorAlert: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var message: String
    public var nextStep: String?

    public init(id: UUID = UUID(), title: String, message: String, nextStep: String? = nil) {
        self.id = id
        self.title = title
        self.message = message
        self.nextStep = nextStep
    }
}
```

```swift
// Sources/EditorCore/EditorDependencies.swift
import Foundation
import PhotoLibraryCore
import RawProcessingCore

public struct EditorDependencies: Sendable {
    public let previewScheduler: PreviewScheduler
    public let previewRenderer: any PreviewRendering
    public let loadAdjustments: @Sendable (PhotoAsset) async throws -> PhotoAdjustments
    public let saveAdjustments: @Sendable (PhotoAdjustments, PhotoAsset) async throws -> Void

    public init(
        previewScheduler: PreviewScheduler,
        previewRenderer: any PreviewRendering,
        loadAdjustments: @escaping @Sendable (PhotoAsset) async throws -> PhotoAdjustments,
        saveAdjustments: @escaping @Sendable (PhotoAdjustments, PhotoAsset) async throws -> Void
    ) {
        self.previewScheduler = previewScheduler
        self.previewRenderer = previewRenderer
        self.loadAdjustments = loadAdjustments
        self.saveAdjustments = saveAdjustments
    }
}
```

```swift
// Sources/AdjustmentUI/BasicAdjustmentPanelModel.swift
import Foundation
import RawProcessingCore

public enum BasicAdjustmentPanelModel {
    public static let rows: [AdjustmentDefinition] = AdjustmentCatalog.ordered
}
```

- [ ] **Step 5: 修正 bookmark options 的平台可用性**

iOS SDK 已驗證 `.withSecurityScope` 為 unavailable；保留 macOS 行為，iPadOS 使用已通過
iOS 17 type-check 的 `.minimalBookmark`／`.withoutUI`：

```swift
private static var creationOptions: URL.BookmarkCreationOptions {
#if os(macOS)
    [.withSecurityScope]
#else
    [.minimalBookmark]
#endif
}

private static var resolutionOptions: URL.BookmarkResolutionOptions {
#if os(macOS)
    [.withSecurityScope]
#else
    [.withoutUI]
#endif
}
```

`makeBookmarkData` 與 `resolve` 分別使用以上 options。`BookmarkError.accessDenied` 的文字
從「macOS denied access」改成平台中立的「The system denied access」，並同步更新英文與
繁體中文 localization。

- [ ] **Step 6: 讓 Metal plugin 依 Xcode 目標平台選 SDK**

在 plugin 產生的 shell script 中，編譯 `.metal` 前加入：

```sh
METAL_SDK=""
METAL_TARGET=""
case "${PLATFORM_NAME:-}" in
    iphoneos)
        METAL_SDK="iphoneos"
        METAL_TARGET="air64-apple-ios${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"
        ;;
    iphonesimulator)
        METAL_SDK="iphonesimulator"
        METAL_TARGET="air64-apple-ios${IPHONEOS_DEPLOYMENT_TARGET:-17.0}-simulator"
        ;;
esac
```

將 `xcrun metal`／`xcrun metallib` 改成有條件的呼叫：Xcode iOS build 使用
`xcrun --sdk "$METAL_SDK" metal -target "$METAL_TARGET"` 及同一 SDK 的 `metallib`；
command-line macOS build 在 `METAL_SDK` 為空時維持目前命令。不得把 iOS deployment
target 硬編成高於本計畫的 17.0。

- [ ] **Step 7: 跑 target 測試、iOS core build 及 macOS 全套測試**

Run: `swift test --filter 'EditorDependenciesTests|BasicAdjustmentPanelModelTests'`

Expected: PASS，2 tests，0 failures。

Run: `swift test`

Expected: 現有全套測試與新增測試全部 PASS，0 failures。

Run: `xcodebuild -scheme RawProcessingCore -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`

Expected: `** BUILD SUCCEEDED **`，產出的 `default.metallib` 為 iOS Simulator 平台。

- [ ] **Step 8: 提交 target 邊界**

```bash
git add Package.swift Plugins/CompileMetalKernels/CompileMetalKernels.swift Sources/EditorCore Sources/AdjustmentUI Sources/PhotoLibraryCore/Access/SecurityScopedBookmark.swift Sources/Localization Tests/EditorCoreTests Tests/AdjustmentUITests
git commit -m "refactor: establish cross-platform editor targets"
```

### Task 2: 抽出共用 EditorSession，保持 Mac 行為不變

**Files:**
- Create: `Sources/EditorCore/EditorSession.swift`
- Delete after move: `Sources/LumaHarborApp/ViewModels/EditorViewModel.swift`
- Modify: `Sources/LumaHarborApp/AppServices.swift`
- Modify: `Sources/LumaHarborApp/ViewModels/LibraryViewModel.swift`
- Modify: `Tests/LumaHarborAppTests/AppTestSupport.swift`
- Modify: `Tests/LumaHarborAppTests/EditorViewModelPreviewTests.swift`
- Modify: `Tests/LumaHarborAppTests/PresetWorkflowTests.swift`
- Create: `Tests/EditorCoreTests/EditorSessionEditingTests.swift`
- Modify: `Package.swift`

**Interfaces:**
- Consumes: `EditorDependencies` from Task 1 and the existing `EditHistory<PhotoAdjustments>` behavior.
- Produces: `@MainActor public final class EditorSession: ObservableObject` with `attach(dependencies:)`, `open(photo:sourceURL:adjustments:isReadOnly:)`, adjustment, Preset, Undo, preview and save APIs matching the current editor behavior.

- [ ] **Step 1: 先寫 EditorSession 編輯與 Undo 的失敗測試**

```swift
// Tests/EditorCoreTests/EditorSessionEditingTests.swift
import Foundation
import XCTest
@testable import EditorCore
import PhotoLibraryCore
import RawProcessingCore

@MainActor
final class EditorSessionEditingTests: XCTestCase {
    func testOneAdjustmentCreatesOneUndoEntry() {
        let editor = EditorSession()
        let photo = PhotoAsset(
            id: PhotoID(),
            libraryID: LibraryID(),
            relativePath: "fixture.ARW",
            fingerprint: FileFingerprint(fileSize: 4, edgeDigest: "fixture"),
            status: .ready
        )
        editor.open(
            photo: photo,
            sourceURL: URL(fileURLWithPath: "/fixture.ARW"),
            adjustments: .neutral,
            isReadOnly: false
        )

        editor.setAdjustment(.exposure, to: 1.25)
        XCTAssertEqual(editor.adjustments.exposure, 1.25)
        XCTAssertTrue(editor.canUndo)

        editor.undo()
        XCTAssertEqual(editor.adjustments.exposure, 0)
        XCTAssertFalse(editor.canUndo)
    }
}
```

- [ ] **Step 2: 把既有 editor regression tests 改為直接匯入 EditorCore**

在兩個測試檔加入：

```swift
@testable import EditorCore
```

在測試 helper 將回傳值改為：

```swift
func makeEditorDependencies(from services: AppServices) -> EditorDependencies {
    EditorDependencies(
        previewScheduler: services.previewScheduler,
        previewRenderer: services.previewRenderer,
        loadAdjustments: services.loadAdjustments,
        saveAdjustments: services.saveAdjustments
    )
}
```

- [ ] **Step 3: 執行 editor tests，確認 EditorSession 尚不存在**

Run: `swift test --filter 'EditorSessionEditingTests|EditorViewModelPreviewTests|PresetWorkflowTests'`

Expected: FAIL，訊息指出 `EditorSession` 或其公開 API 尚不存在。

- [ ] **Step 4: 移動現有實作並進行最小平台中立化**

將 `EditorViewModel.swift` 內容移入 `Sources/EditorCore/EditorSession.swift`，套用下列結構變更；方法本體沿用現有已測邏輯，不重寫排程：

```swift
import Combine
import CoreGraphics
import Foundation
import Localization
import PhotoLibraryCore
import PresetCore
import RawProcessingCore

public enum SaveState: Equatable, Sendable {
    case unchanged
    case pending
    case saving
    case saved(Date)
    case failed(String)

    public var isDirty: Bool {
        switch self {
        case .unchanged, .saved: return false
        case .pending, .saving, .failed: return true
        }
    }
}

@MainActor
public final class EditorSession: ObservableObject {
    @Published public private(set) var photo: PhotoAsset?
    @Published public private(set) var sourceURL: URL?
    @Published public private(set) var previewImage: CGImage?
    @Published public private(set) var originalImage: CGImage?
    @Published public private(set) var saveState: SaveState = .unchanged
    @Published public private(set) var canUndo = false
    @Published public private(set) var canRedo = false
    @Published public var isShowingOriginal = false
    @Published public var alert: EditorAlert?

    private var services: EditorDependencies?

    public init() {}

    public func attach(dependencies: EditorDependencies) {
        guard services == nil else { return }
        services = dependencies
        startObservingPreviews(scheduler: dependencies.previewScheduler)
    }

    // 搬移既有 open/close/edit/preset/preview/autosave 方法；跨 target
    // 需要由 Mac/iPad view 呼叫或讀取的成員標成 public。
}
```

將既有 `UserAlert` 建構位置改成 `EditorAlert`；錯誤轉換集中為：

```swift
public extension EditorAlert {
    init(title: String, error: Error) {
        let localized = error as? LocalizedError
        self.init(
            title: title,
            message: localized?.errorDescription ?? (error as NSError).localizedDescription,
            nextStep: localized?.recoverySuggestion
        )
    }
}
```

下列現有 API 會跨 target 使用，必須明確標為 `public`，不能依賴 `@testable`：
`photo`、`sourceURL`、`previewImage`、`originalImage`、`previewQuality`、`isRendering`、
`decodeFailed`、`saveState`、`canUndo`、`canRedo`、`isShowingOriginal`、`alert`、
`previewPixelDimension`、`onSaved`、`presetPreviewDiagnostics`、`presetPreviewMessage`、
`previewRenderFailureMessage`、`adjustments`、`displayedAdjustments`、`hasEdits`、
`displayedImage`、`canCompareWithOriginal`、`open`、`close`、`setAdjustment`、
`resetAdjustment`、`resetAll`、`undo`、`redo`、`previewPreset`、`cancelPresetPreview`、
`commitPreset`、`save`、`flushPendingEdits`、`retrySaveAfterReconnect`。

- [ ] **Step 5: 讓 Mac composition root 注入新 dependency**

在 `AppServices` 加入：

```swift
var editorDependencies: EditorDependencies {
    EditorDependencies(
        previewScheduler: previewScheduler,
        previewRenderer: previewRenderer,
        loadAdjustments: loadAdjustments,
        saveAdjustments: saveAdjustments
    )
}
```

在 `LibraryViewModel`：

```swift
import EditorCore

let editor = EditorSession()

private func install(services: AppServices) {
    self.services = services
    editor.attach(dependencies: services.editorDependencies)
    editor.onSaved = { [weak self] photoID, hasEdits in
        self?.updateEditBadge(photoID: photoID, hasEdits: hasEdits)
    }
    presetLibrary.attach(myRepository: services.myPresetsRepository)
}
```

`LumaHarborApp` target dependencies 加入 `EditorCore`；`LumaHarborAppTests` dependencies 同步加入。

- [ ] **Step 6: 執行 editor regression tests**

Run: `swift test --filter 'EditorSessionEditingTests|EditorViewModelPreviewTests|PresetWorkflowTests|UndoRedoKeyEquivalentFixTests'`

Expected: 全部 PASS；快速 slider／Preset hover 仍 coalesce、失敗 frame 仍清除、Preset commit 仍只有一筆 Undo。

- [ ] **Step 7: 執行全套測試與 strict-concurrency build**

Run: `swift test`

Expected: 全部 PASS，0 failures。

Run: `swift build -Xswiftc -strict-concurrency=complete`

Expected: Build complete，沒有新增 strict-concurrency error。

- [ ] **Step 8: 提交 EditorCore 抽離**

```bash
git add Package.swift Sources/EditorCore Sources/LumaHarborApp Tests/LumaHarborAppTests
git commit -m "refactor: share editor session across Apple platforms"
```

### Task 3: 抽出十個基本調整的共用 SwiftUI 面板

**Files:**
- Create: `Sources/AdjustmentUI/BasicAdjustmentPanel.swift`
- Modify: `Sources/LumaHarborApp/Views/InspectorView.swift`
- Modify: `Package.swift`
- Test: `Tests/AdjustmentUITests/BasicAdjustmentPanelModelTests.swift`

**Interfaces:**
- Consumes: `EditorSession`, `BasicAdjustmentPanelModel.rows`。
- Produces: `public struct BasicAdjustmentPanel: View`，可嵌入 Mac sidebar、iPad dock／drawer／floating panel。

- [ ] **Step 1: 擴充面板模型測試，鎖定顯示順序與值格式**

```swift
func testExposureIsFirstAndSaturationIsLast() {
    XCTAssertEqual(BasicAdjustmentPanelModel.rows.first?.kind, .exposure)
    XCTAssertEqual(BasicAdjustmentPanelModel.rows.last?.kind, .saturation)
}

func testPositiveValuesCarryAPlusSign() {
    XCTAssertEqual(BasicAdjustmentPanelModel.formatted(1.25, fractionDigits: 2), "+1.25")
    XCTAssertEqual(BasicAdjustmentPanelModel.formatted(0, fractionDigits: 0), "0")
}
```

- [ ] **Step 2: 執行測試並確認 formatter 尚不存在**

Run: `swift test --filter BasicAdjustmentPanelModelTests`

Expected: FAIL，指出 `formatted` 尚不存在。

- [ ] **Step 3: 實作 formatter 與跨平台面板**

```swift
// BasicAdjustmentPanelModel.swift
public static func formatted(_ value: Double, fractionDigits: Int) -> String {
    let text = String(format: "%.*f", fractionDigits, value)
    return value > 0 ? "+\(text)" : text
}
```

```swift
// Sources/AdjustmentUI/BasicAdjustmentPanel.swift
import EditorCore
import Localization
import RawProcessingCore
import SwiftUI

public struct BasicAdjustmentPanel: View {
    @ObservedObject private var editor: EditorSession

    public init(editor: EditorSession) { self.editor = editor }

    public var body: some View {
        ForEach(AdjustmentGroup.allCases, id: \.self) { group in
            Section(group.displayName) {
                ForEach(AdjustmentCatalog.definitions(in: group), id: \.kind) { definition in
                    row(definition)
                }
            }
        }
    }

    private func row(_ definition: AdjustmentDefinition) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(definition.kind.displayName)
                Spacer()
                Text(BasicAdjustmentPanelModel.formatted(
                    editor.adjustments[definition.kind],
                    fractionDigits: definition.fractionDigits
                )).monospacedDigit()
            }
            Slider(
                value: Binding(
                    get: { editor.adjustments[definition.kind] },
                    set: { editor.setAdjustment(definition.kind, to: $0) }
                ),
                in: definition.range
            )
            .accessibilityLabel(Text(definition.kind.displayName))
            .accessibilityValue(Text(BasicAdjustmentPanelModel.formatted(
                editor.adjustments[definition.kind],
                fractionDigits: definition.fractionDigits
            )))
        }
        .contextMenu {
            Button("\(L10n.t("Reset")) \(definition.kind.displayName)") {
                editor.resetAdjustment(definition.kind)
            }
        }
    }
}
```

- [ ] **Step 4: 將 Mac Inspector 改成薄 wrapper**

`InspectorView` 保留 header 與 `PresetBrowserView`；刪除本檔的 `AdjustmentSection`／`AdjustmentSliderRow`，改為：

```swift
import AdjustmentUI

PresetBrowserView()
Divider()
BasicAdjustmentPanel(editor: model.editor)
```

- [ ] **Step 5: 驗證共用面板與 Mac regression**

Run: `swift test --filter 'BasicAdjustmentPanelModelTests|LumaHarborAppTests'`

Expected: 全部 PASS，0 failures。

Run: `swift build -Xswiftc -strict-concurrency=complete`

Expected: PASS。

- [ ] **Step 6: 提交共用面板**

```bash
git add Package.swift Sources/AdjustmentUI Sources/LumaHarborApp/Views/InspectorView.swift Tests/AdjustmentUITests
git commit -m "refactor: share basic adjustment panel"
```

### Task 4: 建立原地／複製兩種單張照片文件儲存

**Files:**
- Create: `Sources/PhotoLibraryCore/Documents/PhotoDocument.swift`
- Create: `Sources/PhotoLibraryCore/Documents/PhotoDocumentStore.swift`
- Create: `Tests/PhotoLibraryCoreTests/PhotoDocumentStoreTests.swift`

**Interfaces:**
- Consumes: `FingerprintCalculator`, `AtomicFileWriter`, `PhotoSidecar`, `SidecarCoding`。
- Produces: `PhotoDocument`、`PhotoDocumentStorageMode`、`PhotoDocumentStore.openInPlace(_:bookmarkData:)`、`importCopy(of:bookmarkData:)`、`loadDocument(id:)`、`loadAdjustments(documentID:)`、`saveAdjustments(_:documentID:)`。

- [ ] **Step 1: 寫入原檔不變與 copy-verify-commit 測試**

```swift
import XCTest
@testable import PhotoLibraryCore
@testable import RawProcessingCore

final class PhotoDocumentStoreTests: XCTestCase {
    func testOpenInPlaceDoesNotWriteTheSource() async throws {
        let fixture = try TemporaryPhotoDocumentFixture()
        let before = try Data(contentsOf: fixture.sourceURL)
        let document = try await fixture.store.openInPlace(fixture.sourceURL, bookmarkData: nil)
        try await fixture.store.saveAdjustments(.neutral.setting(.exposure, to: 1), documentID: document.id)
        XCTAssertEqual(try Data(contentsOf: fixture.sourceURL), before)
        XCTAssertEqual(document.storageMode, .inPlace)
    }

    func testImportCopyVerifiesBytesAndKeepsSourceLink() async throws {
        let fixture = try TemporaryPhotoDocumentFixture()
        let document = try await fixture.store.importCopy(of: fixture.sourceURL, bookmarkData: nil)
        XCTAssertEqual(document.storageMode, .appCopy)
        XCTAssertEqual(document.sourceFingerprint, document.workingFingerprint)
        XCTAssertNotEqual(document.workingURL, fixture.sourceURL)
        XCTAssertEqual(try Data(contentsOf: document.workingURL), try Data(contentsOf: fixture.sourceURL))
    }

    func testReopeningLoadsTheSavedAdjustments() async throws {
        let fixture = try TemporaryPhotoDocumentFixture()
        let document = try await fixture.store.openInPlace(fixture.sourceURL, bookmarkData: nil)
        let edited = PhotoAdjustments.neutral.setting(.contrast, to: 25)
        try await fixture.store.saveAdjustments(edited, documentID: document.id)
        XCTAssertEqual(try await fixture.store.loadAdjustments(documentID: document.id), edited)
    }
}

private struct TemporaryPhotoDocumentFixture {
    let rootURL: URL
    let sourceURL: URL
    let store: PhotoDocumentStore

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoDocumentStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        sourceURL = rootURL.appendingPathComponent("fixture.ARW")
        try Data(repeating: 0x5a, count: 4096).write(to: sourceURL)
        store = PhotoDocumentStore(rootURL: rootURL.appendingPathComponent("Store", isDirectory: true))
    }
}
```

- [ ] **Step 2: 執行測試並確認 API 尚不存在**

Run: `swift test --filter PhotoDocumentStoreTests`

Expected: FAIL，找不到 `PhotoDocumentStore`。

- [ ] **Step 3: 實作文件 model**

```swift
// PhotoDocument.swift
import Foundation

public enum PhotoDocumentStorageMode: String, Codable, Equatable, Sendable {
    case inPlace
    case appCopy
}

public struct PhotoDocument: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let storageMode: PhotoDocumentStorageMode
    public let workingURL: URL
    public let sourceURL: URL
    public let sourceBookmarkData: Data?
    public let sourceFingerprint: FileFingerprint
    public let workingFingerprint: FileFingerprint

    public init(
        id: UUID = UUID(), storageMode: PhotoDocumentStorageMode,
        workingURL: URL, sourceURL: URL, sourceBookmarkData: Data?,
        sourceFingerprint: FileFingerprint, workingFingerprint: FileFingerprint
    ) {
        self.id = id
        self.storageMode = storageMode
        self.workingURL = workingURL
        self.sourceURL = sourceURL
        self.sourceBookmarkData = sourceBookmarkData
        self.sourceFingerprint = sourceFingerprint
        self.workingFingerprint = workingFingerprint
    }
}

public enum PhotoDocumentError: Error, Equatable, Sendable {
    case copyVerificationFailed
    case documentNotFound(UUID)
}
```

- [ ] **Step 4: 實作 actor store 與原子提交**

```swift
public actor PhotoDocumentStore {
    private let rootURL: URL
    private let fileManager: FileManager
    private let copyFile: @Sendable (URL, URL) throws -> Void

    public init(
        rootURL: URL,
        fileManager: FileManager = .default,
        copyFile: (@Sendable (URL, URL) throws -> Void)? = nil
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        self.copyFile = copyFile ?? { source, destination in
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }

    public func openInPlace(_ sourceURL: URL, bookmarkData: Data?) throws -> PhotoDocument {
        let fingerprint = try FingerprintCalculator.fingerprint(forFileAt: sourceURL)
        let document = PhotoDocument(
            storageMode: .inPlace, workingURL: sourceURL, sourceURL: sourceURL,
            sourceBookmarkData: bookmarkData,
            sourceFingerprint: fingerprint, workingFingerprint: fingerprint
        )
        try writeRecord(document)
        return document
    }

    public func importCopy(of sourceURL: URL, bookmarkData: Data?) throws -> PhotoDocument {
        let id = UUID()
        let directory = rootURL.appendingPathComponent("Documents/\(id.uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(sourceURL.lastPathComponent)
            let temporary = directory.appendingPathComponent(".importing")
            try copyFile(sourceURL, temporary)
            let sourceFingerprint = try FingerprintCalculator.fingerprint(forFileAt: sourceURL)
            let copiedFingerprint = try FingerprintCalculator.fingerprint(forFileAt: temporary)
            guard sourceFingerprint == copiedFingerprint else {
                throw PhotoDocumentError.copyVerificationFailed
            }
            try fileManager.moveItem(at: temporary, to: destination)
            let document = PhotoDocument(
                id: id, storageMode: .appCopy, workingURL: destination, sourceURL: sourceURL,
                sourceBookmarkData: bookmarkData,
                sourceFingerprint: sourceFingerprint, workingFingerprint: copiedFingerprint
            )
            try writeRecord(document)
            return document
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    private func writeRecord(_ document: PhotoDocument) throws {
        let url = rootURL.appendingPathComponent("Records/\(document.id.uuidString).json")
        try AtomicFileWriter.write(try SidecarCoding.encode(document), to: url, fileManager: fileManager)
    }

    public func loadDocument(id: UUID) throws -> PhotoDocument {
        let url = rootURL.appendingPathComponent("Records/\(id.uuidString).json")
        guard fileManager.fileExists(atPath: url.path) else {
            throw PhotoDocumentError.documentNotFound(id)
        }
        return try SidecarCoding.decode(PhotoDocument.self, from: Data(contentsOf: url))
    }

    public func loadAdjustments(documentID: UUID) throws -> PhotoAdjustments {
        _ = try loadDocument(id: documentID)
        let repository = try sidecarRepository(documentID: documentID)
        return try repository.loadSidecar(for: PhotoID(documentID))?.adjustments ?? .neutral
    }

    public func saveAdjustments(_ adjustments: PhotoAdjustments, documentID: UUID) throws {
        let document = try loadDocument(id: documentID)
        let repository = try sidecarRepository(documentID: documentID)
        let existing = try repository.loadSidecar(for: PhotoID(documentID))
        let sidecar = existing?.updating(adjustments: adjustments) ?? PhotoSidecar(
            photoID: PhotoID(documentID),
            sourceRelativePath: document.workingURL.lastPathComponent,
            sourceFingerprint: document.workingFingerprint,
            adjustments: adjustments
        )
        try repository.write(sidecar: sidecar)
    }

    private func sidecarRepository(documentID: UUID) throws -> FileSidecarRepository {
        let libraryRoot = rootURL.appendingPathComponent("Sidecars/\(documentID.uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        return FileSidecarRepository(libraryRootURL: libraryRoot, fileManager: fileManager)
    }
}
```

`FileSidecarRepository` 繼續負責原子寫入、schema gate 與損壞隔離；不得在
`PhotoDocumentStore` 重新實作另一套 sidecar codec。找不到 sidecar 時回傳 `.neutral`，
schema 過新或內容損壞時拋錯，不能覆寫。

- [ ] **Step 5: 補齊失敗清理測試並跑全套 PhotoLibraryCoreTests**

加入以下測試，利用 `copyFile` seam 產生不同 bytes：

```swift
func testCopyVerificationFailureLeavesNoDocumentOrRecord() async throws {
    let fixture = try TemporaryPhotoDocumentFixture()
    let failingStoreRoot = fixture.rootURL.appendingPathComponent("FailingStore")
    let store = PhotoDocumentStore(rootURL: failingStoreRoot) { source, destination in
        var bytes = try Data(contentsOf: source)
        bytes[0] ^= 0xff
        try bytes.write(to: destination)
    }

    do {
        _ = try await store.importCopy(of: fixture.sourceURL, bookmarkData: nil)
        XCTFail("Expected copy verification to fail")
    } catch {
        XCTAssertEqual(error as? PhotoDocumentError, .copyVerificationFailed)
    }

    let documents = failingStoreRoot.appendingPathComponent("Documents")
    let records = failingStoreRoot.appendingPathComponent("Records")
    XCTAssertTrue((try? FileManager.default.contentsOfDirectory(atPath: documents.path).isEmpty) ?? true)
    XCTAssertTrue((try? FileManager.default.contentsOfDirectory(atPath: records.path).isEmpty) ?? true)
}
```

Run: `swift test --filter PhotoDocumentStoreTests`

Expected: 至少 4 tests PASS，0 failures。

Run: `swift test --filter PhotoLibraryCoreTests`

Expected: 全部 PASS，0 failures。

- [ ] **Step 6: 提交單張文件 store**

```bash
git add Sources/PhotoLibraryCore/Documents Tests/PhotoLibraryCoreTests/PhotoDocumentStoreTests.swift
git commit -m "feat: add non-destructive photo document storage"
```

### Task 5: 建立可部署的 iPad App shell

**Files:**
- Create: `Apps/LumaHarborPad.swiftpm/Package.swift`
- Create: `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/LumaHarborPadApp.swift`
- Create: `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadRootView.swift`

**Interfaces:**
- Consumes: root package 的 `EditorCore`、`AdjustmentUI`、`PhotoLibraryCore`、`RawProcessingCore`。
- Produces: bundle identifier `com.unizalin.LumaHarborPad`、iPad-only application product `LumaHarborPad`。

- [ ] **Step 1: 建立 iOS application package manifest**

```swift
// Apps/LumaHarborPad.swiftpm/Package.swift
// swift-tools-version: 5.9
import PackageDescription
import AppleProductTypes

let package = Package(
    name: "LumaHarborPad",
    platforms: [.iOS("17.0")],
    products: [
        .iOSApplication(
            name: "LumaHarborPad",
            targets: ["LumaHarborPadApp"],
            bundleIdentifier: "com.unizalin.LumaHarborPad",
            displayVersion: "0.1.0",
            bundleVersion: "1",
            appIcon: .placeholder(icon: .images),
            accentColor: .presetColor(.blue),
            supportedDeviceFamilies: [.pad],
            supportedInterfaceOrientations: [
                .portrait, .portraitUpsideDown, .landscapeRight, .landscapeLeft
            ]
        )
    ],
    dependencies: [
        .package(name: "LumaHarbor", path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "LumaHarborPadApp",
            dependencies: [
                .product(name: "EditorCore", package: "LumaHarbor"),
                .product(name: "AdjustmentUI", package: "LumaHarbor"),
                .product(name: "PhotoLibraryCore", package: "LumaHarbor"),
                .product(name: "RawProcessingCore", package: "LumaHarbor")
            ],
            path: "Sources/LumaHarborPadApp"
        )
    ]
)
```

- [ ] **Step 2: 建立最小 SwiftUI App 與 Files importer**

```swift
// LumaHarborPadApp.swift
import SwiftUI

@main
struct LumaHarborPadApp: App {
    var body: some Scene {
        WindowGroup { PadRootView() }
    }
}
```

```swift
// PadRootView.swift
import SwiftUI
import UniformTypeIdentifiers

struct PadRootView: View {
    @State private var isImporting = false
    @State private var selectedURL: URL?

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Open a RAW photo",
                systemImage: "photo.badge.plus",
                description: Text("Choose a photo from Files or an external drive.")
            )
            .toolbar {
                Button("Open RAW…") { isImporting = true }
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.image, .data],
                allowsMultipleSelection: false
            ) { result in
                selectedURL = try? result.get().first
            }
        }
    }
}
```

- [ ] **Step 3: 做 Simulator build**

Run: `(cd Apps/LumaHarborPad.swiftpm && xcodebuild -scheme LumaHarborPad -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build)`

Expected: `** BUILD SUCCEEDED **`，產生 iOS Simulator `.app`。此 manifest 與命令已用
Xcode 26.6 的暫存最小 iPad App 實際驗證；不得改成只會編譯的普通 library target並宣稱完成。

- [ ] **Step 4: 提交可部署 shell**

```bash
git add Apps/LumaHarborPad.swiftpm
git commit -m "feat: add deployable iPad app shell"
```

### Task 6: 接通原地開啟、複製到 App、預覽與 sidecar 保存

**Files:**
- Create: `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorModel.swift`
- Modify: `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadRootView.swift`
- Create: `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorView.swift`
- Modify: `Sources/Localization/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/Localization/Resources/zh-Hant.lproj/Localizable.strings`
- Create: `Tests/EditorCoreTests/EditorSessionDocumentPersistenceTests.swift`

**Interfaces:**
- Consumes: `PhotoDocumentStore`, `EditorSession`, `CoreImageRawDecoder`, `CoreImagePreviewRenderer`。
- Produces: `PadEditorModel.open(url:mode:)`, `PadOpenMode.inPlace/appCopy` 與可見的編輯畫布。

- [ ] **Step 1: 建立 PadEditorModel 與 dependency composition**

```swift
@MainActor
final class PadEditorModel: ObservableObject {
    enum OpenMode { case inPlace, appCopy }

    @Published private(set) var document: PhotoDocument?
    @Published var alert: EditorAlert?
    let editor = EditorSession()

    private let store: PhotoDocumentStore
    private let decoder: CoreImageRawDecoder
    private var scopedURL: URL?

    init(applicationSupportURL: URL) {
        store = PhotoDocumentStore(rootURL: applicationSupportURL)
        decoder = CoreImageRawDecoder()
        let pipeline = AdjustmentPipeline()
        let renderService = ImageRenderService()
        let renderer = CoreImagePreviewRenderer(
            decoder: decoder, pipeline: pipeline, renderService: renderService
        )
        editor.attach(dependencies: EditorDependencies(
            previewScheduler: PreviewScheduler(renderer: renderer),
            previewRenderer: renderer,
            loadAdjustments: { photo in
                try await store.loadAdjustments(documentID: photo.id.rawValue)
            },
            saveAdjustments: { adjustments, photo in
                try await store.saveAdjustments(adjustments, documentID: photo.id.rawValue)
            }
        ))
    }
}
```

同一步把 iPad `App` composition 改成不會因 Application Support lookup 失敗而 crash：

```swift
@main
struct LumaHarborPadApp: App {
    @StateObject private var model: PadEditorModel

    init() {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        _model = StateObject(wrappedValue: PadEditorModel(applicationSupportURL: support))
    }

    var body: some Scene {
        WindowGroup { PadRootView(model: model) }
    }
}
```

`PadRootView` 以 `@ObservedObject var model: PadEditorModel` 接收同一實例，不能自行建立第二個
`EditorSession`。

`open(url:mode:)` 先呼叫 `url.startAccessingSecurityScopedResource()`，用以下已經 iOS 17 SDK
type-check 通過的方式建立持久 bookmark：

```swift
let bookmark = try url.bookmarkData(
    options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil
)
```

接著在背景 task 執行 fingerprint／copy。建立 `PhotoAsset` 的 identity 必須使用 document ID：

```swift
let metadata = try decoder.readMetadata(at: document.workingURL)
let photo = PhotoAsset(
    id: PhotoID(document.id),
    libraryID: LibraryID(),
    relativePath: document.workingURL.lastPathComponent,
    fingerprint: document.workingFingerprint,
    metadata: metadata,
    status: .ready
)
let adjustments = try await store.loadAdjustments(documentID: document.id)
editor.open(
    photo: photo,
    sourceURL: document.workingURL,
    adjustments: adjustments,
    isReadOnly: false
)
```

原地模式維持 security scope 到 `close()`；App 副本完成 copy 後即可停止來源 scope。
重開原地 document 時以 bookmark resolution `options: [.withoutUI]` 取得 URL，檢查 stale
狀態並再次 `startAccessingSecurityScopedResource()`。autosave 透過 photo ID 寫入 App sidecar，
永遠不把資料寫到 RAW URL。

- [ ] **Step 2: 加入明確的來源模式選擇**

file importer 成功後顯示 `confirmationDialog`：

```swift
.confirmationDialog("How should LumaHarbor use this photo?", isPresented: $showOpenMode) {
    Button("Edit in Place") { openSelected(.inPlace) }
    Button("Copy to This iPad") { openSelected(.appCopy) }
    Button("Cancel", role: .cancel) {}
} message: {
    Text("The RAW original is never modified.")
}
```

原地為第一個/default 動作；兩種模式都顯示 RAW 不會被修改。

- [ ] **Step 3: 接通畫布與共用十個滑桿**

```swift
struct PadEditorView: View {
    @ObservedObject var model: PadEditorModel

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Color.black
                if let image = model.editor.displayedImage {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                } else if model.editor.decodeFailed {
                    ContentUnavailableView("Couldn't show this photo", systemImage: "exclamationmark.triangle")
                } else {
                    ProgressView("Decoding RAW…")
                }
            }
            BasicAdjustmentPanel(editor: model.editor)
                .frame(width: 320)
                .padding()
        }
    }
}
```

- [ ] **Step 4: 驗證 autosave 只寫 sidecar**

建立以下整合測試；它使用真實 `PhotoDocumentStore` 與 `EditorSession` autosave，但用不產生
frame 的 renderer 隔離像素處理：

```swift
// Tests/EditorCoreTests/EditorSessionDocumentPersistenceTests.swift
import Foundation
import XCTest
@testable import EditorCore
import PhotoLibraryCore
import RawProcessingCore

private struct NeverPreviewRenderer: PreviewRendering {
    func render(_ request: PreviewRequest) async throws -> PreviewImage {
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }
}

@MainActor
final class EditorSessionDocumentPersistenceTests: XCTestCase {
    func testAutosavePersistsSidecarWithoutChangingRawBytes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditorDocumentTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rawURL = root.appendingPathComponent("fixture.ARW")
        try Data(repeating: 0x42, count: 4096).write(to: rawURL)
        let original = try Data(contentsOf: rawURL)

        let store = PhotoDocumentStore(rootURL: root.appendingPathComponent("Store"))
        let document = try await store.openInPlace(rawURL, bookmarkData: nil)
        let renderer = NeverPreviewRenderer()
        let editor = EditorSession()
        editor.attach(dependencies: EditorDependencies(
            previewScheduler: PreviewScheduler(renderer: renderer),
            previewRenderer: renderer,
            loadAdjustments: { photo in
                try await store.loadAdjustments(documentID: photo.id.rawValue)
            },
            saveAdjustments: { adjustments, photo in
                try await store.saveAdjustments(adjustments, documentID: photo.id.rawValue)
            }
        ))
        let photo = PhotoAsset(
            id: PhotoID(document.id), libraryID: LibraryID(),
            relativePath: rawURL.lastPathComponent,
            fingerprint: document.workingFingerprint, status: .ready
        )
        editor.open(photo: photo, sourceURL: rawURL, adjustments: .neutral, isReadOnly: false)
        editor.setAdjustment(.exposure, to: 1.5)

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline,
              (try await store.loadAdjustments(documentID: document.id)).exposure != 1.5 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual((try await store.loadAdjustments(documentID: document.id)).exposure, 1.5)
        XCTAssertEqual(try Data(contentsOf: rawURL), original)
    }
}
```

Run: `swift test --filter 'PhotoDocumentStoreTests|EditorSessionEditingTests|EditorSessionDocumentPersistenceTests'`

Expected: 全部 PASS。

- [ ] **Step 5: Simulator build 與人工 smoke test**

Run: `(cd Apps/LumaHarborPad.swiftpm && xcodebuild -scheme LumaHarborPad -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build)`

Expected: `** BUILD SUCCEEDED **`。

人工：在 iPad Simulator 用 Files 選擇可讀影像，確認 dialog、畫布、十個滑桿、Undo 與重開保存；真實 Sony RAW 解碼保留給 Task 8 實機 gate。

- [ ] **Step 6: 提交可編輯垂直路徑**

```bash
git add Apps/LumaHarborPad.swiftpm Sources/Localization
git commit -m "feat: edit a RAW document on iPad"
```

### Task 7: 完成橫向 dock、直向 drawer 與專注浮動面板

**Files:**
- Modify: `Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorView.swift`
- Create: `Sources/AdjustmentUI/PadEditorLayoutPolicy.swift`
- Create: `Tests/AdjustmentUITests/PadEditorLayoutPolicyTests.swift`

**Interfaces:**
- Consumes: `EditorSession`, `BasicAdjustmentPanel`。
- Produces: `PadEditorLayoutPolicy.presentation(forWidth:height:)` 與 `PadWorkspaceMode.work/focus`。

- [ ] **Step 1: 寫 layout policy 測試**

```swift
final class PadEditorLayoutPolicyTests: XCTestCase {
    func testLandscapeUsesDock() {
        XCTAssertEqual(PadEditorLayoutPolicy.presentation(forWidth: 1180, height: 820), .trailingDock)
    }

    func testPortraitUsesBottomDrawer() {
        XCTAssertEqual(PadEditorLayoutPolicy.presentation(forWidth: 820, height: 1180), .bottomDrawer)
    }
}
```

- [ ] **Step 2: 執行測試並確認 policy 尚不存在**

Run: `swift test --filter PadEditorLayoutPolicyTests`

Expected: FAIL，找不到 `PadEditorLayoutPolicy`。

- [ ] **Step 3: 實作純值 layout policy**

```swift
public enum PadInspectorPresentation: Equatable { case trailingDock, bottomDrawer }
public enum PadWorkspaceMode: Equatable { case work, focus }

public enum PadEditorLayoutPolicy {
    public static func presentation(forWidth width: CGFloat, height: CGFloat) -> PadInspectorPresentation {
        width >= height && width >= 900 ? .trailingDock : .bottomDrawer
    }
}
```

此檔須 `import CoreGraphics`，以免共用 target 隱含依賴 SwiftUI 才取得 `CGFloat`。

將純 policy 放在 `AdjustmentUI` 可測 target；iPad view 只決定容器。

- [ ] **Step 4: 實作 B+C 自適應容器**

- `.trailingDock`：畫布 + 320pt 右側 scroll panel。
- `.bottomDrawer`：畫布 + `.sheet`，使用 `.presentationDetents([.height(220), .medium, .large])`，禁止互動 dismiss 造成控制項消失。
- `.focus`：畫布滿版，overlay 浮動 panel；position 以 local UI state 保存。
- work/focus 切換只改 `PadWorkspaceMode`，不得呼叫 editor adjustment 或 history API。

核心切換碼：

```swift
Button {
    workspaceMode = workspaceMode == .work ? .focus : .work
} label: {
    Label("Focus Mode", systemImage: "rectangle.inset.filled")
}
```

- [ ] **Step 5: 驗證切換模式不產生 Undo**

在 view model/policy test 中記錄 `editor.canUndo`，切換 work → focus → work 後仍相同；
再調整 exposure，確認只有調整本身形成一筆 Undo。

Run: `swift test --filter 'PadEditorLayoutPolicyTests|EditorSessionEditingTests'`

Expected: PASS。

- [ ] **Step 6: 提交自適應介面**

```bash
git add Apps/LumaHarborPad.swiftpm Sources/AdjustmentUI Tests/AdjustmentUITests
git commit -m "feat: add adaptive iPad editing workspace"
```

### Task 8: 建立驗收 runner 並在真實 M 系列 iPad 完成 gate

**Files:**
- Create: `Scripts/run-ipad-vertical-slice-acceptance.zsh`
- Create: `docs/testing/reports/2026-08-24-ipad-raw-vertical-slice.md`
- Modify only if needed: `README.md`

**Interfaces:**
- Consumes: 所有前置 tasks。
- Produces: `.build/ipad-vertical-slice/<timestamp>/summary.md` 及遮蔽私人路徑的 logs。

- [ ] **Step 1: 撰寫 fail-fast 驗收 runner**

Runner 必須依序執行：

```zsh
swift build -Xswiftc -strict-concurrency=complete
swift test
(cd Apps/LumaHarborPad.swiftpm && xcodebuild \
  -scheme LumaHarborPad \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build)
Scripts/run-mvp-acceptance.zsh --preflight-only
Scripts/run-mvp-acceptance.zsh
```

每一步把 exit code、PASS／FAIL、實際測試數寫進 `summary.md`；INT／TERM／HUP
沿用 MVP runner 的 signal convention，失敗與未執行步驟原因不得誤標。

- [ ] **Step 2: 加入 summary 隱私 self-test**

Runner 完成後執行：

```zsh
if grep -Eq '/Users/|/Volumes/|/private/var/' "$summary_path"; then
  print -u2 'FAIL: summary contains a private absolute path'
  exit 1
fi
```

另建立 runner self-test，用暫存路徑送出 TERM，驗證 summary 一定產生、Overall FAIL、
沒有殘留 `xcodebuild`／`swift` 子程序。

- [ ] **Step 3: 執行自動驗收**

Run: `Scripts/run-ipad-vertical-slice-acceptance.zsh`

Expected:

```text
strict-concurrency build: PASS
swift test: PASS (0 failures)
iOS Simulator build: PASS
MVP preflight: PASS
MVP acceptance: PASS
Overall result: PASS
```

- [ ] **Step 4: 在真實 M1+ iPad 執行五項 smoke test**

第一次部署時由使用者在 Xcode 26.6 選擇自己的 Development Team；計畫及 repository
不得猜測或硬編 team identifier。簽署完成後再執行以下五項：

1. Files／外接 SSD 原地開啟 Sony RAW，調整 exposure，RAW checksum 不變。
2. 同一 RAW 選「複製到此 iPad」，拔除 SSD 後仍能重開與繼續調整。
3. 連續拖動十個基本滑桿，畫面最後值與控制項一致，沒有永久 spinner 或舊 frame 假成功。
4. work／focus、橫向／直向切換保留照片、調整值、縮放，且不新增 Undo。
5. force quit 後重開 App 副本，最後完整 autosave 能恢復；未完成寫入不覆蓋前一版。

- [ ] **Step 5: 寫入驗收報告**

報告記錄：commit、Xcode version、iPad model／OS、RAW fixture 型號、五項結果、最新
summary 相對路徑及已知限制。任何未執行項目標為 `NOT RUN`，不能標為 PASS。

- [ ] **Step 6: 提交 runner 與證據**

```bash
git add Scripts/run-ipad-vertical-slice-acceptance.zsh docs/testing/reports/2026-08-24-ipad-raw-vertical-slice.md README.md
git commit -m "test: verify iPad RAW editing vertical slice"
```

## Completion Gate

本計畫完成必須同時具備：

- macOS App regression 全綠。
- iOS Simulator `.app` build 成功，不是只有 library target 編譯。
- 真實 M1+ iPad 能從 Files／外接 SSD 開啟 Sony RAW。
- 原地模式與 App 副本模式都能調整、autosave、重開。
- RAW 原檔 checksum 在操作前後一致。
- 十個既有基本調整共享同一 `EditorSession` 與 `BasicAdjustmentPanel`。
- 橫向 dock、直向 drawer、專注浮動面板可用，切換不建立 Undo。
- 最新 acceptance summary 為 PASS，沒有私人絕對路徑。
- 完整照片庫、單一寫入者租約、Preset/XMP UI、批次匯出仍明確列為後續計畫，沒有被誤報為本週完成。

## Spec Coverage and Deferred Plans

本計畫已涵蓋設計 spec 的跨平台 target 邊界、共用 editor session、共用十個基本調整、
原地／App 副本來源、RAW 不改寫、iPad 工作／專注介面、裝置端渲染、錯誤 gate、
Mac regression、Simulator build 與真實 iPad 驗收。

以下設計需求刻意不塞入本週垂直切片，必須各自產生可獨立驗收的後續計畫：

1. 完整多照片圖庫、縮圖、掃描、Files provider 恢復與外接來源重新連結 UI。
2. Mac／iPad 單一寫入者租約、過期判定、唯讀接手與 crash recovery。
3. iPad Preset browser、XMP 檔案匯入／匯出及完整解析度成品匯出。
4. Wave 1–4 的色調曲線、HSL、效果、色彩分級、細節、校正、幾何與裝置端 ML。
5. 裁切、修復／移除、紅眼及遮色片等局部工具路線。

上述項目在其後續驗收完成前，一律不得宣稱十面板或完整 iPad 產品已完成。
