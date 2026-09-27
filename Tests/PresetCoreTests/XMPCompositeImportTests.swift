import Foundation
import XCTest
@testable import PresetCore
import RawProcessingCore

final class XMPCompositeImportTests: XCTestCase {
    func testRecognizedAdobeProfileIsPreservedWithExplicitDiagnostic() throws {
        let xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about=""
          xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
          crs:ProcessVersion="15.4"
          crs:CameraProfile="Adobe Standard"/>
        </rdf:RDF>
        </x:xmpmeta>
        """

        let preview = try XMPImporter().preview(data: Data(xml.utf8), suggestedName: "Profile")

        XCTAssertTrue(preview.preservedProperties.contains(.cameraRaw("CameraProfile")))
        XCTAssertEqual(
            preview.proposedPreset.patch.rawCameraProfile,
            RawCameraProfileSelection(requestedName: "Adobe Standard")
        )
        XCTAssertTrue(preview.diagnostics.contains {
            $0.code == "profilePreservedNotApplied"
                && $0.propertyID == .cameraRaw("CameraProfile")
                && $0.detail == "Adobe Standard"
        })
    }

    func testUnknownAdobeProfileIsPreservedAndRoundTripsWithoutCompatibilityClaim() throws {
        let xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about=""
          xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
          crs:ProcessVersion="15.4"
          crs:CameraProfile="User Owned DCP 42"/>
        </rdf:RDF>
        </x:xmpmeta>
        """

        let preview = try XMPImporter().preview(data: Data(xml.utf8), suggestedName: "Profile")
        XCTAssertEqual(
            preview.proposedPreset.patch.rawCameraProfile?.requestedName,
            "User Owned DCP 42"
        )
        XCTAssertTrue(preview.diagnostics.contains {
            $0.code == "profilePreservedNotApplied"
                && $0.detail == "User Owned DCP 42"
        })

        let exported = try XMPExporter().export(preview.proposedPreset)
        let reparsed = try XMPImporter().preview(data: exported.data, suggestedName: "Profile")
        XCTAssertEqual(
            reparsed.proposedPreset.patch.rawCameraProfile?.requestedName,
            "User Owned DCP 42"
        )
        XCTAssertTrue(reparsed.preservedProperties.contains(.cameraRaw("CameraProfile")))
    }

    func testImportsAdobeBlackAndWhiteMixerIntoMonochromePatch() throws {
        let xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about=""
          xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
          crs:ProcessVersion="15.4"
          crs:ConvertToGrayscale="True"
          crs:GrayMixerRed="+5"
          crs:GrayMixerOrange="+10"
          crs:GrayMixerYellow="+10"
          crs:GrayMixerGreen="-20"
          crs:GrayMixerAqua="-10"
          crs:GrayMixerBlue="-12"
          crs:GrayMixerPurple="+10"
          crs:GrayMixerMagenta="+10"/>
        </rdf:RDF>
        </x:xmpmeta>
        """

        let preview = try XMPImporter().preview(data: Data(xml.utf8), suggestedName: "B&W")

        XCTAssertEqual(
            preview.proposedPreset.patch.monochrome,
            MonochromeAdjustments(isEnabled: true, red: 5, orange: 10, yellow: 10, green: -20,
                                  aqua: -10, blue: -12, purple: 10, magenta: 10)
        )
        XCTAssertTrue(preview.nativeFields.contains(.monochrome))
        XCTAssertFalse(preview.preservedProperties.contains(.cameraRaw("ConvertToGrayscale")))
        XCTAssertFalse(preview.preservedProperties.contains(.cameraRaw("GrayMixerRed")))
    }

    func testAdobeBlackAndWhiteMixerRoundTripsThroughExport() throws {
        let xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about=""
          xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
          crs:ProcessVersion="15.4"
          crs:ConvertToGrayscale="True"
          crs:GrayMixerRed="+5"
          crs:GrayMixerOrange="+10"/>
        </rdf:RDF>
        </x:xmpmeta>
        """

        let preview = try XMPImporter().preview(data: Data(xml.utf8), suggestedName: "B&W")
        let exported = try XMPExporter().export(preview.proposedPreset)
        let reparsed = try XMPImporter().preview(data: exported.data, suggestedName: "B&W")

        XCTAssertEqual(reparsed.proposedPreset.patch.monochrome, preview.proposedPreset.patch.monochrome)
        XCTAssertEqual(reparsed.proposedPreset.patch.monochrome?.red, 5)
        XCTAssertEqual(reparsed.proposedPreset.patch.monochrome?.orange, 10)
    }

    func testImportsAdobeColorGradingIntoColorGradingPatch() throws {
        let xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about=""
          xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
          crs:ProcessVersion="15.4"
          crs:ColorGradeShadowHue="220"
          crs:ColorGradeShadowSat="30"
          crs:ColorGradeShadowLum="-5"
          crs:ColorGradeMidtoneHue="40"
          crs:ColorGradeMidtoneSat="20"
          crs:ColorGradeHighlightHue="60"
          crs:ColorGradeHighlightSat="10"
          crs:ColorGradeGlobalHue="180"
          crs:ColorGradeGlobalSat="5"
          crs:ColorGradeBlending="80"
          crs:ColorGradeBalance="-10"/>
        </rdf:RDF>
        </x:xmpmeta>
        """

        let preview = try XMPImporter().preview(data: Data(xml.utf8), suggestedName: "Color")
        let grading = try XCTUnwrap(preview.proposedPreset.patch.colorGrading)

        XCTAssertEqual(grading.shadows, ColorGradeBand(hue: 220, saturation: 30, luminance: -5))
        XCTAssertEqual(grading.midtones, ColorGradeBand(hue: 40, saturation: 20, luminance: 0))
        XCTAssertEqual(grading.highlights, ColorGradeBand(hue: 60, saturation: 10, luminance: 0))
        XCTAssertEqual(grading.global, ColorGradeBand(hue: 180, saturation: 5, luminance: 0))
        XCTAssertEqual(grading.blending, 80)
        XCTAssertEqual(grading.balance, -10)
        XCTAssertTrue(preview.nativeFields.contains(.colorGrading))
        XCTAssertFalse(preview.preservedProperties.contains(.cameraRaw("ColorGradeShadowHue")))
    }

    func testImportsAdobeNoiseReductionAmountsIntoNoiseReductionPatch() throws {
        let xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about=""
          xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
          crs:ProcessVersion="15.4"
          crs:LuminanceSmoothing="13"
          crs:LuminanceNoiseReductionDetail="50"
          crs:ColorNoiseReduction="25"
          crs:ColorNoiseReductionDetail="40"/>
        </rdf:RDF>
        </x:xmpmeta>
        """

        let preview = try XMPImporter().preview(data: Data(xml.utf8), suggestedName: "Noise")
        let noise = try XCTUnwrap(preview.proposedPreset.patch.noiseReduction)

        XCTAssertEqual(noise.luminanceAmount, 13)
        XCTAssertEqual(noise.luminanceDetail, 50)
        XCTAssertEqual(noise.colorAmount, 25)
        XCTAssertEqual(noise.colorDetail, 40)
        XCTAssertTrue(preview.approximateFields.contains(.noiseReductionLuminanceAmount))
        XCTAssertTrue(preview.approximateFields.contains(.noiseReductionColorAmount))
        XCTAssertFalse(preview.preservedProperties.contains(.cameraRaw("ColorNoiseReduction")))
    }

    func testImportsAdobeLensProfileEnableIntoAutomaticLensCorrection() throws {
        let xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about=""
          xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
          crs:ProcessVersion="15.4"
          crs:LensProfileEnable="1"/>
        </rdf:RDF>
        </x:xmpmeta>
        """

        let preview = try XMPImporter().preview(data: Data(xml.utf8), suggestedName: "Lens")

        XCTAssertEqual(preview.proposedPreset.patch.lensCorrection?.mode, .automatic)
        XCTAssertTrue(preview.nativeFields.contains(.lensCorrection))
        XCTAssertFalse(preview.preservedProperties.contains(.cameraRaw("LensProfileEnable")))
    }

    func testAdobeColorNoiseAndLensFieldsRoundTripThroughExport() throws {
        let xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about=""
          xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
          crs:ProcessVersion="15.4"
          crs:ColorGradeShadowSat="30"
          crs:ColorGradeBalance="-10"
          crs:LuminanceSmoothing="13"
          crs:ColorNoiseReduction="25"
          crs:LensProfileEnable="1"/>
        </rdf:RDF>
        </x:xmpmeta>
        """

        let preview = try XMPImporter().preview(data: Data(xml.utf8), suggestedName: "Composite")
        let exported = try XMPExporter().export(preview.proposedPreset)
        let reparsed = try XMPImporter().preview(data: exported.data, suggestedName: "Composite")

        XCTAssertEqual(reparsed.proposedPreset.patch.colorGrading?.shadows.saturation, 30)
        XCTAssertEqual(reparsed.proposedPreset.patch.colorGrading?.balance, -10)
        XCTAssertEqual(reparsed.proposedPreset.patch.noiseReduction?.luminanceAmount, 13)
        XCTAssertEqual(reparsed.proposedPreset.patch.noiseReduction?.colorAmount, 25)
        XCTAssertEqual(reparsed.proposedPreset.patch.lensCorrection?.mode, .automatic)
    }

    func testImportsAndExportsAdobeParametricToneCurve() throws {
        let xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about=""
          xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
          crs:ProcessVersion="15.4"
          crs:ParametricShadows="-5"
          crs:ParametricDarks="+5"
          crs:ParametricLights="-40"
          crs:ParametricHighlights="-20"
          crs:ParametricShadowSplit="11"
          crs:ParametricMidtoneSplit="75"
          crs:ParametricHighlightSplit="90"/>
        </rdf:RDF>
        </x:xmpmeta>
        """

        let preview = try XMPImporter().preview(data: Data(xml.utf8), suggestedName: "Parametric")
        let curve = try XCTUnwrap(preview.proposedPreset.patch.advancedToneCurve)
        XCTAssertEqual(curve.parametric, ParametricToneCurve(
            shadows: -5, darks: 5, lights: -40, highlights: -20,
            shadowSplit: 11, midtoneSplit: 75, highlightSplit: 90
        ))
        XCTAssertTrue(preview.nativeFields.contains(.advancedToneCurve))
        XCTAssertFalse(preview.preservedProperties.contains(.cameraRaw("ParametricShadows")))

        let exported = try XMPExporter().export(preview.proposedPreset)
        let reparsed = try XMPImporter().preview(data: exported.data, suggestedName: "Parametric")
        XCTAssertEqual(reparsed.proposedPreset.patch.advancedToneCurve?.parametric, curve.parametric)
    }
}
