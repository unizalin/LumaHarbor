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

    func testInlineHostHasAllFiveDomainEntries() throws {
        let source = try Self.load("PadEditorView.swift")
        for key in [".adjust", ".preset", ".geometry", ".local", ".info"] {
            XCTAssertTrue(source.contains("DomainBarItem(id: \(key)"))
        }
    }
}
