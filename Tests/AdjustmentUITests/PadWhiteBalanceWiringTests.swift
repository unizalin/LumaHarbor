import Foundation
import XCTest

/// Auxiliary composition guard. Native input behavior is separately exercised
/// by AdjustmentValueInputNativeTests; this is not iPad UI-event evidence.
final class PadWhiteBalanceWiringTests: XCTestCase {
    func testBothIPadInspectorEntrypointsMountTheWhiteBalanceControls() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for file in ["PadInspectorHost.swift", "PadEditorView.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(
                "Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/" + file), encoding: .utf8)
            XCTAssertTrue(source.contains(".temperature") && source.contains(".tint")
                          && source.contains(".vibrance") && source.contains(".saturation"), file)
            XCTAssertTrue(source.contains("case .color:")
                          && source.contains("BasicAdjustmentPanel(editor: editor, kinds: Self.colorKinds)"),
                "\(file) currently mounts only HSL; the repaired Kelvin/Tint controls must be reachable")
        }
    }

    func testIPadEditorProvidesA44PointEyedropperEntryAndExplicitCancel() throws {
        let source = try loadPadEditorSource()
        XCTAssertTrue(source.contains("PadWhiteBalanceEyedropperButton"),
                      "iPad must expose the shared white-balance eyedropper entry")
        XCTAssertTrue(source.contains("frame(minWidth: 44, minHeight: 44)"),
                      "the iPad eyedropper entry must remain a 44 pt touch target")
        XCTAssertTrue(source.contains("editor.cancelEyedropperPreview()"),
                      "cancelling the iPad tool must restore the committed preview")
        XCTAssertTrue(source.contains("L10n.t(\"Cancel Eyedropper\")"),
                      "the active iPad entry must have an explicit localized cancel label")
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sharedHost = try String(contentsOf: root.appendingPathComponent(
            "Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadInspectorHost.swift"), encoding: .utf8)
        XCTAssertTrue(sharedHost.contains("PadWhiteBalanceEyedropperButton"),
                      "the standalone iPad inspector host must use the same entry")
    }

    func testIPadCanvasMountsAWhiteBalanceOverlayAndPinsTheDisplayedFrame() throws {
        let source = try loadPadEditorSource()
        XCTAssertTrue(source.contains("PadEyedropperOverlayView("),
                      "the iPad canvas must mount the eyedropper overlay")
        XCTAssertTrue(source.contains("editor.toolMode == .whiteBalance"),
                      "the overlay must only be active in white-balance tool mode")
        XCTAssertTrue(source.contains("beginEyedropperSampling(sourceImage: image)"),
                      "sampling must pin the exact displayed image frame at press time")
        XCTAssertTrue(source.contains("commitEyedropper(context: snapshot.context)"),
                      "release must commit the original gesture context once")
    }

    func testIPadEyedropperPausesCanvasZoomWhileSampling() throws {
        let source = try loadPadEditorSource()
        XCTAssertTrue(source.contains("if isSamplingEyedropper"),
                      "canvas gesture routing must branch for the eyedropper")
        XCTAssertTrue(source.contains("MagnificationGesture()"),
                      "normal canvas zoom must remain available outside sampling")
        XCTAssertTrue(source.contains("isSamplingEyedropper"),
                      "the eyedropper must explicitly pause zoom during its gesture")
    }

    private func loadPadEditorSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(
            "Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorView.swift"), encoding: .utf8)
    }
}
