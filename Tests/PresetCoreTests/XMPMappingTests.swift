import XCTest
@testable import PresetCore

/// Table-driven coverage of every mapping `XMPMappingRegistry.default` ships
/// with Phase 1 (spec §7, plan Task 4 step 1: "測試清單必須直接列出 registry 第一版
/// 每個 property；不要用「其餘類似」省略"). Each row below names one real
/// property; `testEveryDefaultMappingRoundTrips` asserts every row against the
/// registry and, via `testTableCoversExactlyTheRegisteredMappings`, that the
/// table and the registry never drift apart in either direction.
final class XMPMappingTests: XCTestCase {
    private struct MappingCase {
        let propertyID: XMPPropertyID
        let field: AdjustmentFieldID
        let level: XMPCompatibilityLevel
        let importText: String
        let expectedValue: Double
        /// `nil` for the two white-balance leaves: they have no generic
        /// `exportScalar` because whether the stored number is an absolute
        /// Kelvin/tint or a LumaHarbor-relative offset depends on
        /// `PresetDocument.source`, which `XMPExporter` resolves itself
        /// rather than the per-property closure (spec §7).
        let expectedExportText: String?

        init(
            _ propertyID: XMPPropertyID,
            _ field: AdjustmentFieldID,
            _ level: XMPCompatibilityLevel,
            importText: String,
            expectedValue: Double,
            expectedExportText: String? = nil
        ) {
            self.propertyID = propertyID
            self.field = field
            self.level = level
            self.importText = importText
            self.expectedValue = expectedValue
            self.expectedExportText = expectedExportText
        }
    }

    // Every mapping `buildDefaultMappings()` registers, spelled out one at a
    // time -- not generated from a loop -- so a reviewer can see the entire
    // Phase 1 mapping surface here without cross-referencing the registry.
    private static let cases: [MappingCase] = [
        // MARK: Basic -- native
        MappingCase(.cameraRaw("Exposure2012"), .basicExposure, .native, importText: "+0.50", expectedValue: 0.5, expectedExportText: "0.5"),
        MappingCase(.cameraRaw("Vibrance"), .basicVibrance, .native, importText: "+20", expectedValue: 20, expectedExportText: "20"),
        MappingCase(.cameraRaw("Saturation"), .basicSaturation, .native, importText: "-5", expectedValue: -5, expectedExportText: "-5"),

        // MARK: Basic -- contextual white balance (no generic exportScalar)
        MappingCase(.cameraRaw("Temperature"), .basicTemperature, .native, importText: "5500", expectedValue: 5500),
        MappingCase(.cameraRaw("Tint"), .basicTint, .native, importText: "+11", expectedValue: 11),

        // MARK: Basic -- approximate (different tone-mapping algorithm)
        MappingCase(.cameraRaw("Contrast2012"), .basicContrast, .approximate, importText: "+15", expectedValue: 15, expectedExportText: "15"),
        MappingCase(.cameraRaw("Highlights2012"), .basicHighlights, .approximate, importText: "-30", expectedValue: -30, expectedExportText: "-30"),
        MappingCase(.cameraRaw("Shadows2012"), .basicShadows, .approximate, importText: "+25", expectedValue: 25, expectedExportText: "25"),
        MappingCase(.cameraRaw("Whites2012"), .basicWhites, .approximate, importText: "+10", expectedValue: 10, expectedExportText: "10"),
        MappingCase(.cameraRaw("Blacks2012"), .basicBlacks, .approximate, importText: "-10", expectedValue: -10, expectedExportText: "-10"),

        // MARK: HSL -- native, all eight bands
        MappingCase(.cameraRaw("HueAdjustmentRed"), .hslRedHue, .native, importText: "-20", expectedValue: -20, expectedExportText: "-20"),
        MappingCase(.cameraRaw("SaturationAdjustmentRed"), .hslRedSaturation, .native, importText: "+15", expectedValue: 15, expectedExportText: "15"),
        MappingCase(.cameraRaw("LuminanceAdjustmentRed"), .hslRedLuminance, .native, importText: "-5", expectedValue: -5, expectedExportText: "-5"),
        MappingCase(.cameraRaw("HueAdjustmentOrange"), .hslOrangeHue, .native, importText: "+5", expectedValue: 5, expectedExportText: "5"),
        MappingCase(.cameraRaw("SaturationAdjustmentOrange"), .hslOrangeSaturation, .native, importText: "-10", expectedValue: -10, expectedExportText: "-10"),
        MappingCase(.cameraRaw("LuminanceAdjustmentOrange"), .hslOrangeLuminance, .native, importText: "+10", expectedValue: 10, expectedExportText: "10"),
        MappingCase(.cameraRaw("HueAdjustmentYellow"), .hslYellowHue, .native, importText: "+10", expectedValue: 10, expectedExportText: "10"),
        MappingCase(.cameraRaw("SaturationAdjustmentYellow"), .hslYellowSaturation, .native, importText: "+20", expectedValue: 20, expectedExportText: "20"),
        MappingCase(.cameraRaw("LuminanceAdjustmentYellow"), .hslYellowLuminance, .native, importText: "-15", expectedValue: -15, expectedExportText: "-15"),
        MappingCase(.cameraRaw("HueAdjustmentGreen"), .hslGreenHue, .native, importText: "-5", expectedValue: -5, expectedExportText: "-5"),
        MappingCase(.cameraRaw("SaturationAdjustmentGreen"), .hslGreenSaturation, .native, importText: "-20", expectedValue: -20, expectedExportText: "-20"),
        MappingCase(.cameraRaw("LuminanceAdjustmentGreen"), .hslGreenLuminance, .native, importText: "+5", expectedValue: 5, expectedExportText: "5"),
        MappingCase(.cameraRaw("HueAdjustmentAqua"), .hslAquaHue, .native, importText: "+15", expectedValue: 15, expectedExportText: "15"),
        MappingCase(.cameraRaw("SaturationAdjustmentAqua"), .hslAquaSaturation, .native, importText: "+10", expectedValue: 10, expectedExportText: "10"),
        MappingCase(.cameraRaw("LuminanceAdjustmentAqua"), .hslAquaLuminance, .native, importText: "-10", expectedValue: -10, expectedExportText: "-10"),
        MappingCase(.cameraRaw("HueAdjustmentBlue"), .hslBlueHue, .native, importText: "-10", expectedValue: -10, expectedExportText: "-10"),
        MappingCase(.cameraRaw("SaturationAdjustmentBlue"), .hslBlueSaturation, .native, importText: "+5", expectedValue: 5, expectedExportText: "5"),
        MappingCase(.cameraRaw("LuminanceAdjustmentBlue"), .hslBlueLuminance, .native, importText: "+20", expectedValue: 20, expectedExportText: "20"),
        MappingCase(.cameraRaw("HueAdjustmentPurple"), .hslPurpleHue, .native, importText: "+20", expectedValue: 20, expectedExportText: "20"),
        MappingCase(.cameraRaw("SaturationAdjustmentPurple"), .hslPurpleSaturation, .native, importText: "-5", expectedValue: -5, expectedExportText: "-5"),
        MappingCase(.cameraRaw("LuminanceAdjustmentPurple"), .hslPurpleLuminance, .native, importText: "-20", expectedValue: -20, expectedExportText: "-20"),
        MappingCase(.cameraRaw("HueAdjustmentMagenta"), .hslMagentaHue, .native, importText: "-15", expectedValue: -15, expectedExportText: "-15"),
        MappingCase(.cameraRaw("SaturationAdjustmentMagenta"), .hslMagentaSaturation, .native, importText: "-15", expectedValue: -15, expectedExportText: "-15"),
        MappingCase(.cameraRaw("LuminanceAdjustmentMagenta"), .hslMagentaLuminance, .native, importText: "+15", expectedValue: 15, expectedExportText: "15"),

        // MARK: Split toning -- native
        MappingCase(.cameraRaw("SplitToningShadowHue"), .splitToningShadowHue, .native, importText: "210", expectedValue: 210, expectedExportText: "210"),
        MappingCase(.cameraRaw("SplitToningShadowSaturation"), .splitToningShadowSaturation, .native, importText: "15", expectedValue: 15, expectedExportText: "15"),
        MappingCase(.cameraRaw("SplitToningHighlightHue"), .splitToningHighlightHue, .native, importText: "50", expectedValue: 50, expectedExportText: "50"),
        MappingCase(.cameraRaw("SplitToningHighlightSaturation"), .splitToningHighlightSaturation, .native, importText: "10", expectedValue: 10, expectedExportText: "10"),
        MappingCase(.cameraRaw("SplitToningBalance"), .splitToningBalance, .native, importText: "-5", expectedValue: -5, expectedExportText: "-5"),

        // MARK: Sharpening -- approximate. Sharpness rescales Adobe's 0...100
        // onto LumaHarbor's 0...150.
        MappingCase(.cameraRaw("Sharpness"), .sharpeningAmount, .approximate, importText: "40", expectedValue: 60, expectedExportText: "40"),
        MappingCase(.cameraRaw("SharpenRadius"), .sharpeningRadius, .approximate, importText: "1", expectedValue: 1, expectedExportText: "1"),

        // MARK: Vignette -- approximate
        MappingCase(.cameraRaw("PostCropVignetteAmount"), .vignetteAmount, .approximate, importText: "-25", expectedValue: -25, expectedExportText: "-25"),
        MappingCase(.cameraRaw("PostCropVignetteMidpoint"), .vignetteMidpoint, .approximate, importText: "50", expectedValue: 50, expectedExportText: "50"),
        MappingCase(.cameraRaw("PostCropVignetteFeather"), .vignetteFeather, .approximate, importText: "50", expectedValue: 50, expectedExportText: "50"),
        MappingCase(.cameraRaw("PostCropVignetteRoundness"), .vignetteRoundness, .approximate, importText: "0", expectedValue: 0, expectedExportText: "0"),

        // MARK: Grain -- approximate. `GrainFrequency` is the on-disk name
        // behind the "Roughness" slider (Adobe kept the legacy property name).
        MappingCase(.cameraRaw("GrainAmount"), .grainAmount, .approximate, importText: "25", expectedValue: 25, expectedExportText: "25"),
        MappingCase(.cameraRaw("GrainSize"), .grainSize, .approximate, importText: "25", expectedValue: 25, expectedExportText: "25"),
        MappingCase(.cameraRaw("GrainFrequency"), .grainRoughness, .approximate, importText: "50", expectedValue: 50, expectedExportText: "50")
    ]

    func testEveryDefaultMappingRoundTrips() throws {
        let registry = XMPMappingRegistry.default
        for testCase in Self.cases {
            guard let mapping = registry.mapping(for: testCase.propertyID) else {
                XCTFail("No mapping registered for \(testCase.propertyID)")
                continue
            }
            XCTAssertEqual(mapping.field, testCase.field, "\(testCase.propertyID) field")
            XCTAssertEqual(mapping.level, testCase.level, "\(testCase.propertyID) level")

            let imported = try mapping.importScalar(.text(testCase.importText))
            XCTAssertEqual(imported, testCase.expectedValue, accuracy: 1e-9, "\(testCase.propertyID) import")

            // Every field must also be reachable by field lookup, and agree
            // with the property-keyed lookup above.
            XCTAssertEqual(registry.mapping(for: testCase.field)?.propertyID, testCase.propertyID)

            guard let expectedExportText = testCase.expectedExportText else {
                XCTAssertNil(mapping.exportScalar, "\(testCase.propertyID) should have no generic exportScalar")
                continue
            }
            guard let exportScalar = mapping.exportScalar else {
                XCTFail("\(testCase.propertyID) is missing its exportScalar")
                continue
            }
            let exported = try exportScalar(testCase.expectedValue)
            XCTAssertEqual(exported, .text(expectedExportText), "\(testCase.propertyID) export")

            // Round-tripping the *original* imported number back through
            // export and re-import must reproduce it (proves the scale
            // factor, e.g. Sharpness's *1.5, is truly symmetric).
            let reimported = try mapping.importScalar(try exportScalar(imported))
            XCTAssertEqual(reimported, imported, accuracy: 1e-6, "\(testCase.propertyID) round trip")
        }
    }

    /// Guards against the table and the registry drifting apart: every
    /// mapping the registry ships must appear above, and nothing above may
    /// name a mapping the registry doesn't have.
    func testTableCoversExactlyTheRegisteredMappings() {
        let registry = XMPMappingRegistry.default
        let registeredIDs = Set(registry.mappings.map(\.propertyID))
        let tableIDs = Set(Self.cases.map(\.propertyID))
        XCTAssertEqual(registeredIDs, tableIDs)
    }

    // MARK: - Process version recognition

    func testProcessVersionAtMinimumIsRecognized() {
        XCTAssertTrue(XMPMappingRegistry.isRecognizedProcessVersion("6.7"))
    }

    func testProcessVersionAboveMinimumIsRecognized() {
        XCTAssertTrue(XMPMappingRegistry.isRecognizedProcessVersion("15.4"))
    }

    func testProcessVersionBelowMinimumIsNotRecognized() {
        XCTAssertFalse(XMPMappingRegistry.isRecognizedProcessVersion("6.0"))
    }

    func testMissingProcessVersionIsNotRecognized() {
        XCTAssertFalse(XMPMappingRegistry.isRecognizedProcessVersion(nil))
    }

    func testUnparsableProcessVersionIsNotRecognized() {
        XCTAssertFalse(XMPMappingRegistry.isRecognizedProcessVersion("not-a-version"))
    }

    // MARK: - Preserved-only properties (spec §7's own examples)

    func testSharpeningDetailHasNoMapping() {
        XCTAssertNil(XMPMappingRegistry.default.mapping(for: .cameraRaw("SharpenDetail")))
    }

    func testSharpeningMaskingHasNoMapping() {
        XCTAssertNil(XMPMappingRegistry.default.mapping(for: .cameraRaw("SharpenEdgeMasking")))
    }

    func testIndependentLuminanceNoiseReductionHasNoMapping() {
        XCTAssertNil(XMPMappingRegistry.default.mapping(for: .cameraRaw("LuminanceSmoothing")))
    }

    func testIndependentColorNoiseReductionHasNoMapping() {
        XCTAssertNil(XMPMappingRegistry.default.mapping(for: .cameraRaw("ColorNoiseReduction")))
    }

    func testCameraProfileHasNoMapping() {
        XCTAssertNil(XMPMappingRegistry.default.mapping(for: .cameraRaw("CameraProfile")))
    }

    func testUnknownNamespacePropertyHasNoMapping() {
        XCTAssertNil(XMPMappingRegistry.default.mapping(for: XMPPropertyID(namespaceURI: "urn:test:future", localName: "MaskTree")))
    }

    func testLegacyProcess2003ExposureNameHasNoMapping() {
        // Adobe renamed both the property and the algorithm at Process 2012;
        // the legacy pre-2012 name is deliberately not mapped (spec §7: don't
        // guess an equivalence without a verified fixture).
        XCTAssertNil(XMPMappingRegistry.default.mapping(for: .cameraRaw("Exposure")))
    }

    // MARK: - Malformed values

    func testImportScalarThrowsOnNonNumericText() {
        let mapping = try! XCTUnwrap(XMPMappingRegistry.default.mapping(for: .cameraRaw("Exposure2012")))
        XCTAssertThrowsError(try mapping.importScalar(.text("not-a-number"))) {
            guard case .malformedXML = $0 as? PresetError else {
                return XCTFail("Expected .malformedXML, got \($0)")
            }
        }
    }

    func testImportScalarThrowsOnNonTextValue() {
        let mapping = try! XCTUnwrap(XMPMappingRegistry.default.mapping(for: .cameraRaw("Exposure2012")))
        XCTAssertThrowsError(try mapping.importScalar(.array(kind: .seq, values: []))) {
            guard case .malformedXML = $0 as? PresetError else {
                return XCTFail("Expected .malformedXML, got \($0)")
            }
        }
    }
}
