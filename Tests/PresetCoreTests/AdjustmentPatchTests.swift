import XCTest
@testable import PresetCore
import RawProcessingCore

final class AdjustmentPatchTests: XCTestCase {
    // MARK: - Absent vs explicit default

    func testBasicPatchDistinguishesAbsentFromExplicitNeutral() throws {
        let absent = AdjustmentPatch()
        let explicit = AdjustmentPatch(basic: .init(exposure: 0))
        XCTAssertFalse(absent.contains(.basicExposure))
        XCTAssertTrue(explicit.contains(.basicExposure))
        XCTAssertNotEqual(absent, explicit)
    }

    func testEmptyNestedPatchCanonicalizesToNil() {
        XCTAssertNil(AdjustmentPatch(basic: BasicAdjustmentPatch()).basic)
        XCTAssertNil(AdjustmentPatch(hsl: HSLAdjustmentPatch()).hsl)
        XCTAssertNil(AdjustmentPatch(splitToning: SplitToningPatch()).splitToning)
        XCTAssertNil(AdjustmentPatch(sharpening: SharpeningPatch()).sharpening)
        XCTAssertNil(AdjustmentPatch(noiseReduction: NoiseReductionPatch()).noiseReduction)
        XCTAssertNil(AdjustmentPatch(vignette: VignettePatch()).vignette)
        XCTAssertNil(AdjustmentPatch(grain: GrainPatch()).grain)
    }

    func testEmptyHSLBandPatchCanonicalizesToNilWithinParent() {
        var hsl = HSLAdjustmentPatch()
        hsl.red = HSLBandPatch()
        hsl.orange = HSLBandPatch(hue: 5)
        let canonical = hsl.canonicalized()
        XCTAssertNil(canonical?.red)
        XCTAssertNotNil(canonical?.orange)
    }

    // MARK: - Table-driven coverage of every AdjustmentFieldID

    private func makePatch(settingOnly field: AdjustmentFieldID, to value: Double = 12) -> AdjustmentPatch {
        var patch = AdjustmentPatch()
        switch field {
        case .basicExposure: patch.basic = BasicAdjustmentPatch(exposure: value)
        case .basicTemperature: patch.basic = BasicAdjustmentPatch(temperature: value)
        case .basicTint: patch.basic = BasicAdjustmentPatch(tint: value)
        case .basicContrast: patch.basic = BasicAdjustmentPatch(contrast: value)
        case .basicHighlights: patch.basic = BasicAdjustmentPatch(highlights: value)
        case .basicShadows: patch.basic = BasicAdjustmentPatch(shadows: value)
        case .basicWhites: patch.basic = BasicAdjustmentPatch(whites: value)
        case .basicBlacks: patch.basic = BasicAdjustmentPatch(blacks: value)
        case .basicVibrance: patch.basic = BasicAdjustmentPatch(vibrance: value)
        case .basicSaturation: patch.basic = BasicAdjustmentPatch(saturation: value)
        case .advancedToneCurve: patch.advancedToneCurve = AdvancedToneCurve(points: [ToneCurvePoint(x: 0.2, y: 0.3)])
        case .hslRedHue: patch.hsl = HSLAdjustmentPatch(red: HSLBandPatch(hue: value))
        case .hslRedSaturation: patch.hsl = HSLAdjustmentPatch(red: HSLBandPatch(saturation: value))
        case .hslRedLuminance: patch.hsl = HSLAdjustmentPatch(red: HSLBandPatch(luminance: value))
        case .hslOrangeHue: patch.hsl = HSLAdjustmentPatch(orange: HSLBandPatch(hue: value))
        case .hslOrangeSaturation: patch.hsl = HSLAdjustmentPatch(orange: HSLBandPatch(saturation: value))
        case .hslOrangeLuminance: patch.hsl = HSLAdjustmentPatch(orange: HSLBandPatch(luminance: value))
        case .hslYellowHue: patch.hsl = HSLAdjustmentPatch(yellow: HSLBandPatch(hue: value))
        case .hslYellowSaturation: patch.hsl = HSLAdjustmentPatch(yellow: HSLBandPatch(saturation: value))
        case .hslYellowLuminance: patch.hsl = HSLAdjustmentPatch(yellow: HSLBandPatch(luminance: value))
        case .hslGreenHue: patch.hsl = HSLAdjustmentPatch(green: HSLBandPatch(hue: value))
        case .hslGreenSaturation: patch.hsl = HSLAdjustmentPatch(green: HSLBandPatch(saturation: value))
        case .hslGreenLuminance: patch.hsl = HSLAdjustmentPatch(green: HSLBandPatch(luminance: value))
        case .hslAquaHue: patch.hsl = HSLAdjustmentPatch(aqua: HSLBandPatch(hue: value))
        case .hslAquaSaturation: patch.hsl = HSLAdjustmentPatch(aqua: HSLBandPatch(saturation: value))
        case .hslAquaLuminance: patch.hsl = HSLAdjustmentPatch(aqua: HSLBandPatch(luminance: value))
        case .hslBlueHue: patch.hsl = HSLAdjustmentPatch(blue: HSLBandPatch(hue: value))
        case .hslBlueSaturation: patch.hsl = HSLAdjustmentPatch(blue: HSLBandPatch(saturation: value))
        case .hslBlueLuminance: patch.hsl = HSLAdjustmentPatch(blue: HSLBandPatch(luminance: value))
        case .hslPurpleHue: patch.hsl = HSLAdjustmentPatch(purple: HSLBandPatch(hue: value))
        case .hslPurpleSaturation: patch.hsl = HSLAdjustmentPatch(purple: HSLBandPatch(saturation: value))
        case .hslPurpleLuminance: patch.hsl = HSLAdjustmentPatch(purple: HSLBandPatch(luminance: value))
        case .hslMagentaHue: patch.hsl = HSLAdjustmentPatch(magenta: HSLBandPatch(hue: value))
        case .hslMagentaSaturation: patch.hsl = HSLAdjustmentPatch(magenta: HSLBandPatch(saturation: value))
        case .hslMagentaLuminance: patch.hsl = HSLAdjustmentPatch(magenta: HSLBandPatch(luminance: value))
        case .splitToningShadowHue: patch.splitToning = SplitToningPatch(shadowHue: value)
        case .splitToningShadowSaturation: patch.splitToning = SplitToningPatch(shadowSaturation: value)
        case .splitToningHighlightHue: patch.splitToning = SplitToningPatch(highlightHue: value)
        case .splitToningHighlightSaturation: patch.splitToning = SplitToningPatch(highlightSaturation: value)
        case .splitToningBalance: patch.splitToning = SplitToningPatch(balance: value)
        case .sharpeningAmount: patch.sharpening = SharpeningPatch(amount: value)
        case .sharpeningRadius: patch.sharpening = SharpeningPatch(radius: value)
        case .sharpeningDetail: patch.sharpening = SharpeningPatch(detail: value)
        case .sharpeningMasking: patch.sharpening = SharpeningPatch(masking: value)
        case .noiseReductionLuminanceAmount: patch.noiseReduction = NoiseReductionPatch(luminanceAmount: value)
        case .noiseReductionLuminanceDetail: patch.noiseReduction = NoiseReductionPatch(luminanceDetail: value)
        case .noiseReductionColorAmount: patch.noiseReduction = NoiseReductionPatch(colorAmount: value)
        case .noiseReductionColorDetail: patch.noiseReduction = NoiseReductionPatch(colorDetail: value)
        case .vignetteAmount: patch.vignette = VignettePatch(amount: value)
        case .vignetteMidpoint: patch.vignette = VignettePatch(midpoint: value)
        case .vignetteRoundness: patch.vignette = VignettePatch(roundness: value)
        case .vignetteFeather: patch.vignette = VignettePatch(feather: value)
        case .grainAmount: patch.grain = GrainPatch(amount: value)
        case .grainSize: patch.grain = GrainPatch(size: value)
        case .grainRoughness: patch.grain = GrainPatch(roughness: value)
        }
        return patch
    }

    func testEveryFieldIDCanBeSetInIsolationAndDetected() {
        for field in AdjustmentFieldID.allCases {
            let patch = makePatch(settingOnly: field)
            XCTAssertTrue(patch.contains(field), "Expected \(field) to be present")
            let others = AdjustmentFieldID.allCases.filter { $0 != field }
            for other in others where !relatedByCurve(field, other) {
                XCTAssertFalse(patch.contains(other), "\(other) unexpectedly present when only \(field) was set")
            }
        }
    }

    /// `advancedToneCurve` is a single whole-value leaf; no other field shares
    /// its parent, so this always returns false, but the helper stays generic
    /// in case that changes.
    private func relatedByCurve(_ a: AdjustmentFieldID, _ b: AdjustmentFieldID) -> Bool { false }

    func testAdjustmentFieldIDRawValuesAreStable() {
        XCTAssertEqual(AdjustmentFieldID.basicExposure.rawValue, "basic.exposure")
        XCTAssertEqual(AdjustmentFieldID.hslRedHue.rawValue, "hsl.red.hue")
        XCTAssertEqual(AdjustmentFieldID.sharpeningAmount.rawValue, "sharpening.amount")
        XCTAssertEqual(AdjustmentFieldID.advancedToneCurve.rawValue, "advancedToneCurve")
        XCTAssertEqual(AdjustmentFieldID.allCases.count, Set(AdjustmentFieldID.allCases.map(\.rawValue)).count)
    }

    // MARK: - Codable round-trip

    func testAdjustmentPatchRoundTripsThroughJSON() throws {
        let patch = AdjustmentPatch(
            basic: BasicAdjustmentPatch(exposure: 1.5, saturation: -20),
            advancedToneCurve: AdvancedToneCurve(points: [ToneCurvePoint(x: 0, y: 0), ToneCurvePoint(x: 1, y: 1)]),
            hsl: HSLAdjustmentPatch(red: HSLBandPatch(hue: 10, saturation: 20, luminance: -5)),
            splitToning: SplitToningPatch(shadowHue: 220, shadowSaturation: 15),
            sharpening: SharpeningPatch(amount: 40),
            noiseReduction: NoiseReductionPatch(luminanceAmount: 25),
            vignette: VignettePatch(amount: -30),
            grain: GrainPatch(amount: 10)
        )
        let data = try JSONEncoder().encode(patch)
        let decoded = try JSONDecoder().decode(AdjustmentPatch.self, from: data)
        XCTAssertEqual(patch, decoded)
    }

    func testDecodingEmptyJSONObjectProducesFullyAbsentPatch() throws {
        let data = Data("{}".utf8)
        let decoded = try JSONDecoder().decode(AdjustmentPatch.self, from: data)
        XCTAssertEqual(decoded, AdjustmentPatch())
        XCTAssertTrue(decoded.isEmpty)
    }
}
