import EditorCore
import Foundation
import RawProcessingCore
import XCTest
@testable import AdjustmentUI

final class MaskOverlayTests: XCTestCase {
    func testRadialPositionIsNormalizedAndClamped() {
        let base = LocalAdjustmentGeometry(x: 0.5, y: 0.5)
        let result = RadialMaskDragMath.updatedPosition(
            base: base,
            translation: CGSize(width: 600, height: -600),
            imageFrameSize: CGSize(width: 400, height: 300)
        )

        XCTAssertEqual(result.x, 1, accuracy: 0.0001)
        XCTAssertEqual(result.y, 0, accuracy: 0.0001)
    }

    func testRadialHorizontalAndVerticalRadiiUseTheirOwnAxes() {
        let base = LocalAdjustmentGeometry(radius: 0.25, radialRadiusY: 0.4)
        let horizontal = RadialMaskDragMath.updatedRadius(
            base: base,
            translation: CGSize(width: 100, height: 300),
            axis: .horizontal,
            imageFrameSize: CGSize(width: 400, height: 300)
        )
        let vertical = RadialMaskDragMath.updatedRadius(
            base: base,
            translation: CGSize(width: 100, height: -150),
            axis: .vertical,
            imageFrameSize: CGSize(width: 400, height: 300)
        )

        XCTAssertEqual(horizontal.radius, 0.583333, accuracy: 0.0001)
        XCTAssertEqual(horizontal.radialRadiusY ?? -1, 0.4, accuracy: 0.0001)
        XCTAssertEqual(vertical.radialRadiusY ?? -1, 0.01, accuracy: 0.0001)
        XCTAssertEqual(vertical.radius, 0.25, accuracy: 0.0001)
    }

    func testBrushLocationUsesTopLeftNormalizedCoordinates() {
        let point = BrushMaskDragMath.normalizedPoint(
            at: CGPoint(x: 250, y: 50),
            in: CGRect(x: 50, y: 20, width: 400, height: 200)
        )

        XCTAssertEqual(point.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(point.y, 0.15, accuracy: 0.0001)
    }

    func testBrushLocationClampsPointerOvershootToThePhoto() {
        let point = BrushMaskDragMath.normalizedPoint(
            at: CGPoint(x: -20, y: 300),
            in: CGRect(x: 0, y: 0, width: 100, height: 100)
        )

        XCTAssertEqual(point.x, 0, accuracy: 0.0001)
        XCTAssertEqual(point.y, 1, accuracy: 0.0001)
    }

    func testBothPlatformCanReachRadialAndBrushCanvasTools() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let editorView = try String(
            contentsOf: root.appendingPathComponent("Sources/LumaHarborApp/Views/EditorView.swift"),
            encoding: .utf8
        )
        let padView = try String(
            contentsOf: root.appendingPathComponent("Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorView.swift"),
            encoding: .utf8
        )

        for source in [editorView, padView] {
            XCTAssertTrue(source.contains("toolMode == .radialGradient"))
            XCTAssertTrue(source.contains("RadialMaskOverlayView("))
            XCTAssertTrue(source.contains("toolMode == .brush"))
            XCTAssertTrue(source.contains("BrushMaskOverlayView("))
        }
    }
}
