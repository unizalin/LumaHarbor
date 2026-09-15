import XCTest

final class PadPortraitInspectorContractTests: XCTestCase {
    private static let appSourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp")

    private static func load(_ name: String) throws -> String {
        try String(contentsOf: appSourceURL.appendingPathComponent(name), encoding: .utf8)
    }

    func testBothHostsUseExplicitFiveItemEqualWidthBar() throws {
        for name in ["PadEditorView.swift", "PadInspectorHost.swift"] {
            let source = try Self.load(name)
            XCTAssertTrue(
                source.contains("GeometryReader"),
                "\(name) must size the compact domain bar from its available width"
            )
            XCTAssertTrue(
                source.contains("domainBarItems.count"),
                "\(name) must derive each tab width from the five-item count"
            )
            XCTAssertTrue(
                source.contains("minHeight: 44"),
                "\(name) must keep the compact domain bar hit target"
            )
        }
    }

    func testEditorExposesBothInspectorEntrypointsAndDismissibleSheet() throws {
        let source = try Self.load("PadEditorView.swift")
        XCTAssertTrue(source.contains("inspectorLauncher"))
        XCTAssertTrue(source.contains("inspectorToggle"))
        XCTAssertTrue(source.contains("L10n.t(\"Show Inspector\")"))
        XCTAssertTrue(source.contains("interactiveDismissDisabled(false)"))
        XCTAssertTrue(source.contains("PadBottomDrawerPolicy.shouldShowLauncher"))
        XCTAssertTrue(source.contains("overlay(alignment: .trailing)"))
    }

    func testInspectorLauncherUsesA44PointCircularHitTarget() throws {
        let source = try Self.load("PadEditorView.swift")
        XCTAssertTrue(source.contains("frame(width: 44, height: 44)"))
        XCTAssertTrue(source.contains("Circle()"))
        XCTAssertTrue(source.contains("Show, hide, or resize workspace panels"))
    }

    func testSheetDismissalOnlyClearsVisibilityForWorkMode() throws {
        let source = try Self.load("PadEditorView.swift")
        guard let start = source.range(of: ".onChange(of: isDrawerPresented)") else {
            return XCTFail("PadEditorView.swift must observe sheet dismissal")
        }
        let dismissalTail = source[start.lowerBound...]
        guard let end = dismissalTail.range(of: "\n                }\n        }") else {
            return XCTFail("PadEditorView.swift must keep the dismissal handler bounded")
        }
        let dismissalBlock = dismissalTail[..<end.lowerBound]
        XCTAssertTrue(
            dismissalBlock.contains("workspaceState.workspaceMode == .work"),
            "focus-mode policy dismissal must preserve inspector visibility"
        )
    }

    func testInlineHostHasAllFiveDomainEntries() throws {
        let source = try Self.load("PadEditorView.swift")
        for key in [".adjust", ".preset", ".geometry", ".local", ".info"] {
            XCTAssertTrue(source.contains("DomainBarItem(id: \(key)"))
        }
    }
}
