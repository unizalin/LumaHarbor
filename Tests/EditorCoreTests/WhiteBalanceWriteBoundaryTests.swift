import Combine
import CoreGraphics
import Foundation
import XCTest
@testable import EditorCore
import PhotoLibraryCore
import PresetCore
import RawProcessingCore

struct BaselinePreviewRenderer: PreviewRendering {
    var baseline: Double? = 5500
    func render(_ request: PreviewRequest) async throws -> PreviewImage {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return PreviewImage(cgImage: context.makeImage()!, pixelSize: CGSize(width: 1, height: 1),
            whiteBalanceBaseline: baseline.map { RawWhiteBalanceBaseline(temperatureKelvin: $0, tint: 0) })
    }
}

@MainActor
final class WhiteBalanceWriteBoundaryTests: XCTestCase {
    func makeEditor(baseline: Double? = 5500, adjustments: PhotoAdjustments = .neutral) async -> EditorSession {
        let renderer = BaselinePreviewRenderer(baseline: baseline)
        let editor = EditorSession()
        editor.attach(dependencies: EditorDependencies(previewScheduler: PreviewScheduler(renderer: renderer),
            previewRenderer: renderer, loadAdjustments: { _ in .neutral }, saveAdjustments: { _, _ in }))
        let frame = expectation(description: "accepted frame")
        let subscription = editor.$previewImage.compactMap { $0 }.first().sink { _ in frame.fulfill() }
        editor.open(photo: PhotoAsset(id: PhotoID(), libraryID: LibraryID(), relativePath: "fixture.ARW",
            fingerprint: FileFingerprint(fileSize: 4, edgeDigest: "fixture"), status: .ready),
            sourceURL: URL(fileURLWithPath: "/tmp/fixture.ARW"), adjustments: adjustments, isReadOnly: false)
        await fulfillment(of: [frame], timeout: 2)
        withExtendedLifetime(subscription) {}
        return editor
    }

    func testNewSetAndUpdateUsePhotoSpecificBoundary() async {
        let editor = await makeEditor()
        editor.setAdjustment(.temperature, to: -100)
        XCTAssertEqual(editor.adjustments.temperature, -3500 / 45, accuracy: 1e-9)
        editor.updateAdjustments { $0.temperature = -2000 }
        XCTAssertEqual(editor.adjustments.temperature, -3500 / 45, accuracy: 1e-9)
        editor.close()
    }

    func testNonFiniteNewTemperaturePreservesAuthoritativeValue() async {
        let editor = await makeEditor(adjustments: PhotoAdjustments(temperature: 10))
        editor.setAdjustment(.temperature, to: .nan)
        XCTAssertEqual(editor.adjustments.temperature, 10)
        editor.updateAdjustments { $0.temperature = .infinity; $0.exposure = 1 }
        XCTAssertEqual(editor.adjustments.temperature, 10)
        XCTAssertEqual(editor.adjustments.exposure, 1)
        editor.close()
    }

    func testNewTemperatureWriteKeepsItsClampDiagnosticAfterRendering() async {
        let editor = await makeEditor()
        editor.setAdjustment(.temperature, to: -100)
        XCTAssertEqual(editor.whiteBalanceDiagnostic, .clamped)
        let frame = expectation(description: "clamped write rendered")
        let subscription = editor.$previewImage.dropFirst().compactMap { $0 }.first().sink { _ in frame.fulfill() }
        await fulfillment(of: [frame], timeout: 2)
        XCTAssertEqual(editor.whiteBalanceDiagnostic, .clamped)
        editor.updateAdjustments { $0.temperature = 2000 }
        XCTAssertEqual(editor.whiteBalanceDiagnostic, .clamped)
        editor.setAdjustment(.temperature, to: 10)
        XCTAssertEqual(editor.whiteBalanceDiagnostic, .none)
        withExtendedLifetime(subscription) {}
        editor.close()
    }

    func testMissingOrInvalidBaselineRejectsRelativeWritesAndEyedropper() async {
        for baseline: Double? in [nil, .nan, .infinity, 0, -1, 1999, 50001] {
            let editor = await makeEditor(baseline: baseline)
            editor.setAdjustment(.temperature, to: 10)
            XCTAssertEqual(editor.adjustments.temperature, 0)
            editor.previewEyedropper(sample: .init(red: 0.6, green: 0.5, blue: 0.4))
            XCTAssertFalse(editor.hasEyedropperPreview)
            XCTAssertFalse(editor.commitEyedropper())
            editor.close()
        }
    }

    func testEyedropperPreservesClampedResolutionDiagnostic() async {
        let editor = await makeEditor()
        editor.previewEyedropper(sample: .init(red: 0.6, green: 0.5, blue: 0.4))
        XCTAssertEqual(editor.displayedAdjustments.temperature, -3500 / 45, accuracy: 1e-9)
        XCTAssertEqual(editor.whiteBalanceDiagnostic, .clamped)
        editor.close()
    }

    func testClampedDiagnosticSurvivesCommitAndItsRenderedFrame() async {
        let editor = await makeEditor()
        editor.previewEyedropper(sample: .init(red: 0.6, green: 0.5, blue: 0.4))
        XCTAssertTrue(editor.commitEyedropper())
        XCTAssertEqual(editor.whiteBalanceDiagnostic, .clamped)
        let frame = expectation(description: "committed render")
        let subscription = editor.$previewImage.dropFirst().compactMap { $0 }.first().sink { _ in frame.fulfill() }
        await fulfillment(of: [frame], timeout: 2)
        XCTAssertEqual(editor.whiteBalanceDiagnostic, .clamped)
        withExtendedLifetime(subscription) {}
        editor.close()
    }

    func testLateReleaseSampleCannotReauthorizeAnInvalidatedGesture() async {
        let editor = await makeEditor()
        let sample = WhiteBalanceEyedropper.Sample(red: 0.6, green: 0.5, blue: 0.4)
        editor.previewEyedropper(sample: sample)
        editor.setAdjustment(.exposure, to: 1)
        editor.previewEyedropper(sample: sample)
        XCTAssertFalse(editor.commitEyedropper())
        XCTAssertEqual(editor.adjustments.temperature, 0)
        XCTAssertEqual(editor.adjustments.exposure, 1)
        editor.undo()
        XCTAssertEqual(editor.adjustments.exposure, 0)
        XCTAssertFalse(editor.canUndo)
        editor.close()
    }

    func testNoOpResetDoesNotPermanentlyMakeTheDisplayedFrameUnsampleable() async throws {
        let editor = await makeEditor()
        let image = try XCTUnwrap(editor.previewImage)
        editor.resetAdjustment(.exposure)
        XCTAssertNotNil(editor.beginEyedropperSampling(sourceImage: image),
            "the exact unchanged authoritative recipe is still a valid sampling source")
        editor.close()
    }

    func testImplicitSamplingCannotPairAnOldFrameWithANewRecipe() async {
        let editor = await makeEditor()
        editor.setAdjustment(.exposure, to: 1)
        // The old bitmap is still displayed; no new render has completed.
        editor.previewEyedropper(sample: .init(red: 0.6, green: 0.5, blue: 0.4))
        XCTAssertFalse(editor.hasEyedropperPreview)
        XCTAssertFalse(editor.commitEyedropper())
        XCTAssertEqual(editor.adjustments.temperature, 0)
        editor.close()
    }

    func testUnrelatedEditAndUndoPreserveFiniteLegacyTemperature() async {
        var legacy = PhotoAdjustments.neutral
        legacy.temperature = -2000 // Model a decoded legacy sidecar, not a new clamped edit.
        let editor = await makeEditor(adjustments: legacy)
        editor.updateAdjustments { $0.exposure = 1 }
        XCTAssertEqual(editor.adjustments.temperature, -2000)
        editor.setAdjustment(.temperature, to: -100)
        editor.undo()
        XCTAssertEqual(editor.adjustments.temperature, -2000)
        editor.close()
    }

    func testNativeAndXMPPresetPreviewCommitAndDiagnosticsAgree() async {
        for baseline: Double? in [nil, .nan, 4536.72802734375] {
            for absolute in [false, true] {
                for value in absolute ? [6000.0, 1000, 60000] : [10.0, -100, 2000] {
                    let editor = await makeEditor(baseline: baseline, adjustments: PhotoAdjustments(temperature: 12))
                    let preset = PresetDocument(name: "WB matrix", source: absolute ? .adobeXMP(tool: nil, version: nil) : .native,
                        patch: AdjustmentPatch(basic: .init(exposure: 1, temperature: value)))
                    editor.previewPreset(preset, mode: .merge)
                    let expected: Double
                    let limited: Bool
                    if let baseline, baseline.isFinite {
                        let raw = absolute ? (value - baseline) / 45 : value
                        expected = min(max(raw, (2000 - baseline) / 45), (50000 - baseline) / 45)
                        limited = expected != raw
                    } else {
                        expected = 12
                        limited = true
                    }
                    XCTAssertEqual(editor.displayedAdjustments.temperature, expected, accuracy: 1e-9)
                    XCTAssertEqual(editor.displayedAdjustments.exposure, 1)
                    XCTAssertEqual(!editor.presetPreviewDiagnostics.isEmpty, limited)
                    XCTAssertEqual(editor.adjustments.temperature, 12)
                    XCTAssertEqual(editor.saveState, .unchanged)
                    let preview = editor.displayedAdjustments
                    editor.commitPreset(preset, mode: .merge)
                    XCTAssertEqual(editor.adjustments, preview)
                    XCTAssertEqual(editor.alert != nil, limited)
                    editor.undo()
                    XCTAssertEqual(editor.adjustments.temperature, 12)
                    XCTAssertEqual(editor.adjustments.exposure, 0)
                    XCTAssertFalse(editor.canUndo)
                    editor.close()
                }
            }
        }
    }
}
