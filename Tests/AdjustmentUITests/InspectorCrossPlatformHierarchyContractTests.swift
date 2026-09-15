import Foundation
import XCTest

final class InspectorCrossPlatformHierarchyContractTests: XCTestCase {
    private static let repositoryRootURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }()

    private static let iPadHostPaths = [
        "Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadInspectorHost.swift",
        "Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorView.swift",
    ]

    func testBothIPadHostsUseTheSharedLevel1Hierarchy() throws {
        for relativePath in Self.iPadHostPaths {
            let source = try String(
                contentsOf: Self.repositoryRootURL.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            XCTAssertTrue(
                source.contains("InspectorLevel1DisclosureGroup"),
                "\(relativePath) must use the shared Level 1 hierarchy component"
            )
            XCTAssertTrue(
                source.contains("expandedSections"),
                "\(relativePath) must preserve section expansion state"
            )
        }
    }

    func testDedicatedIPadDomainsKeepTheirLevel1PageHost() throws {
        for relativePath in Self.iPadHostPaths {
            let source = try String(
                contentsOf: Self.repositoryRootURL.appendingPathComponent(relativePath),
                encoding: .utf8
            )

            XCTAssertTrue(
                source.contains("domainSection("),
                "\(relativePath) must host dedicated pages in a Level 1 section"
            )
            XCTAssertTrue(
                source.contains(".geometry") && source.contains(".local"),
                "\(relativePath) must expose Geometry and Local as dedicated Level 1 domains"
            )
            XCTAssertTrue(
                source.contains("summary.localizedText"),
                "\(relativePath) must preserve the collapsed adjusted/not-adjusted summary"
            )
        }
    }

    func testMacDedicatedDomainsKeepTheSameLevel1PageHost() throws {
        let source = try String(
            contentsOf: Self.repositoryRootURL.appendingPathComponent(
                "Sources/LumaHarborApp/Views/InspectorView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(
            source.contains("case .geometry:\n                    ScrollView {\n                        inspectorGroup(.geometry") &&
                source.contains("case .local:\n                    ScrollView {\n                        inspectorGroup(.local"),
            "macOS Geometry and Local tabs must use the same Level 1 host as iPad"
        )
        XCTAssertTrue(
            source.contains("GeometryAdjustmentPanel(editor: model.editor)") &&
                source.contains("LocalAdjustmentsPanel(editor: model.editor)"),
            "the shared page host must preserve both dedicated adjustment panels"
        )
        XCTAssertTrue(
            source.contains(".onChange(of: selectedTab)") &&
                source.contains("expandedGroups.insert(.geometry)") &&
                source.contains("expandedGroups.insert(.local)"),
            "switching to a dedicated page must reveal its page-level content"
        )
    }

    func testCatalogSearchDoesNotReplacePresetOrInfoPageControls() throws {
        let source = try String(
            contentsOf: Self.repositoryRootURL.appendingPathComponent(
                "Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(
            source.contains("private var showsCatalogNavigation"),
            "the Xcode iPad host must make catalog search visibility explicit"
        )
        XCTAssertTrue(
            source.contains("case .adjust, .geometry, .local:"),
            "catalog navigation belongs to editable adjustment domains"
        )
        XCTAssertTrue(
            source.contains("case .preset, .info:"),
            "Preset and Info must keep their own page-specific controls"
        )
        XCTAssertTrue(
            source.contains("if showsCatalogNavigation,\n               !navigation.searchQuery"),
            "catalog results must not intercept Preset or Info content"
        )
    }

    func testGeometrySlidersUseContinuousPreviewLifecycle() throws {
        let source = try String(
            contentsOf: Self.repositoryRootURL.appendingPathComponent(
                "Sources/AdjustmentUI/GeometryAdjustmentPanel.swift"
            ),
            encoding: .utf8
        )
        let previewCount = source.components(separatedBy: "onPreview:").count - 1
        let commitCount = source.components(separatedBy: "onCommitPreview:").count - 1

        XCTAssertGreaterThanOrEqual(
            previewCount,
            6,
            "Geometry sliders should render live without recording every drag tick"
        )
        XCTAssertEqual(
            previewCount,
            commitCount,
            "Each Geometry preview must commit exactly once when the gesture ends"
        )
    }

    func testLocalAdjustmentSlidersUseContinuousPreviewLifecycle() throws {
        let source = try String(
            contentsOf: Self.repositoryRootURL.appendingPathComponent(
                "Sources/AdjustmentUI/LocalAdjustmentsPanel.swift"
            ),
            encoding: .utf8
        )
        let sliderCount = source.components(separatedBy: "AdjustmentSliderRow(").count - 1
        let previewCount = source.components(separatedBy: "onPreview:").count - 1
        let commitCount = source.components(separatedBy: "onCommitPreview:").count - 1

        XCTAssertGreaterThanOrEqual(
            sliderCount,
            19,
            "Local mask and repair controls should keep their full slider surface"
        )
        XCTAssertEqual(
            sliderCount,
            previewCount,
            "Every Local slider must preview continuously instead of committing every tick"
        )
        XCTAssertEqual(
            previewCount,
            commitCount,
            "Every Local preview must commit exactly once when the gesture ends"
        )
    }

    func testIPadCanvasMountsEveryInteractiveLocalMaskOverlay() throws {
        let source = try String(
            contentsOf: Self.repositoryRootURL.appendingPathComponent(
                "Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorView.swift"
            ),
            encoding: .utf8
        )

        for expected in [
            "RadialMaskOverlayView(editor: editor, imageFrame: imageFrame)",
            "BrushMaskOverlayView(editor: editor, imageFrame: imageFrame)",
            "LinearGradientMaskOverlayView(editor: editor, imageFrame: imageFrame)",
            "SpotHealMaskOverlayView(editor: editor, imageFrame: imageFrame)",
        ] {
            XCTAssertTrue(source.contains(expected), "iPad canvas must mount \(expected)")
        }
    }

    func testIPadAdvancedMaskOverlaysUse44PointTouchTargets() throws {
        let source = try String(
            contentsOf: Self.repositoryRootURL.appendingPathComponent(
                "Sources/AdjustmentUI/PadAdvancedMaskOverlayViews.swift"
            ),
            encoding: .utf8
        )

        XCTAssertEqual(source.components(separatedBy: "private static let handleHitAreaSize: CGFloat = 44").count - 1, 2)
        XCTAssertGreaterThanOrEqual(source.components(separatedBy: ".frame(width: Self.handleHitAreaSize, height: Self.handleHitAreaSize)").count - 1, 2)
    }

    func testIPadInspectorToolbarControlsKeepStableTouchHeights() throws {
        let source = try String(
            contentsOf: Self.repositoryRootURL.appendingPathComponent(
                "Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorView.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(
            source.contains("private var catalogSearchField: some View") && source.contains(".frame(minHeight: 44)"),
            "the iPad catalog search control must keep a stable 44pt touch height even before text is entered"
        )
        for relativePath in Self.iPadHostPaths {
            let host = try String(
                contentsOf: Self.repositoryRootURL.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            XCTAssertTrue(
                host.contains("private var submodePicker: some View") && host.contains(".pickerStyle(.segmented)\n        .frame(minHeight: 44)"),
                "\(relativePath) must keep the wide adjustment submode picker at the same 44pt height as its menu fallback"
            )
        }
    }

    func testIPadDomainNavigationUsesTheWholeStableCellAsTheHitArea() throws {
        let editorSource = try String(
            contentsOf: Self.repositoryRootURL.appendingPathComponent(
                "Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorView.swift"
            ),
            encoding: .utf8
        )
        let railSource = try String(
            contentsOf: Self.repositoryRootURL.appendingPathComponent(
                "Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadToolRail.swift"
            ),
            encoding: .utf8
        )
        let standaloneHostSource = try String(
            contentsOf: Self.repositoryRootURL.appendingPathComponent(
                "Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadInspectorHost.swift"
            ),
            encoding: .utf8
        )

        guard let editorRailFrame = editorSource.range(of: ".frame(minWidth: 64, minHeight: 44)") else {
            XCTFail("the Xcode host's vertical rail must declare a 44pt cell")
            return
        }
        let editorRailAfterFrame = String(editorSource[editorRailFrame.upperBound...].prefix(260))
        XCTAssertTrue(
            editorRailAfterFrame.contains(".contentShape(Rectangle())"),
            "the Xcode host's vertical rail must make the full 44pt cell tappable"
        )
        XCTAssertTrue(
            railSource.contains(".frame(minWidth: 64, minHeight: 44)\n            .contentShape(Rectangle())"),
            "the shared SwiftPM rail must make the full 44pt cell tappable"
        )
        XCTAssertTrue(
            editorSource.contains(".frame(minWidth: 88, minHeight: 52)\n                        .contentShape(Rectangle())") &&
                standaloneHostSource.contains(".frame(minWidth: 88, minHeight: 52)\n                        .contentShape(Rectangle())"),
            "compact domain bars must make their full label cell tappable on both hosts"
        )
    }

    func testSharedInspectorPickersUsePlatformTouchMetrics() throws {
        for relativePath in [
            "Sources/AdjustmentUI/GeometryAdjustmentPanel.swift",
            "Sources/AdjustmentUI/LocalAdjustmentsPanel.swift",
            "Sources/AdjustmentUI/RenderingProfilePanel.swift"
        ] {
            let source = try String(
                contentsOf: Self.repositoryRootURL.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            XCTAssertTrue(
                source.contains("AdjustmentControlMetrics.actionMinimumHeight"),
                "\(relativePath) must use the shared platform-specific picker/action height"
            )
        }
    }
}
