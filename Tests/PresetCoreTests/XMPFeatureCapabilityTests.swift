import XCTest
@testable import PresetCore

final class XMPFeatureCapabilityTests: XCTestCase {
    func testDefaultManifestUsesNamespaceQualifiedIDsAndCoversEveryExistingMapping() throws {
        let manifest = XMPCapabilityManifest.default
        let mappedIDs = Set(XMPMappingRegistry.default.mappings.map(\.propertyID))
        let manifestIDs = Set(manifest.capabilities.flatMap(\.propertyIDs))

        XCTAssertTrue(mappedIDs.isSubset(of: manifestIDs))
        XCTAssertTrue(manifest.capabilities.allSatisfy {
            $0.propertyIDs.allSatisfy { $0.namespaceURI == XMPNamespace.cameraRaw }
        })
        XCTAssertTrue(manifest.capabilities.contains {
            $0.feature == .toneCurve && $0.level == .native
        })
    }

    func testDefaultManifestCoversCompositeAdobeFeatures() {
        let manifest = XMPCapabilityManifest.default
        XCTAssertTrue(manifest.capabilities(for: .monochrome).contains {
            $0.propertyIDs.contains(.cameraRaw("ConvertToGrayscale"))
                && $0.propertyIDs.contains(.cameraRaw("GrayMixerRed"))
        })
        XCTAssertTrue(manifest.capabilities(for: .colorGrading).contains {
            $0.propertyIDs.contains(.cameraRaw("ColorGradeShadowHue"))
                && $0.propertyIDs.contains(.cameraRaw("ColorGradeBlending"))
        })
        XCTAssertTrue(manifest.capabilities(for: .lensCorrection).contains {
            $0.propertyIDs == [.cameraRaw("LensProfileEnable")]
        })
        XCTAssertTrue(manifest.capabilities(for: .renderingProfile).contains {
            $0.propertyIDs == [.cameraRaw("CameraProfile")]
                && $0.level == .preserved
                && $0.direction == .importOnly
                && $0.rendererEvidenceID == "profile.preservedNotApplied"
        })
    }

    func testAdobeProfileRegistryRecognizesCorpusNamesAndTrimsInput() throws {
        XCTAssertEqual(
            AdobeProfileRegistry.descriptor(for: "  Adobe Standard ")?.name,
            "Adobe Standard"
        )
        XCTAssertEqual(AdobeProfileRegistry.descriptor(for: "Adobe Color")?.level, .preserved)
        XCTAssertNil(AdobeProfileRegistry.descriptor(for: "Camera Standard"))
        XCTAssertEqual(AdobeProfileRegistry.recognizedNames, ["Adobe Standard", "Adobe Color"])
    }

    func testManifestRejectsDuplicatePropertyOwnership() {
        XCTAssertNil(XMPCapabilityManifest(capabilities: [
            XMPFeatureCapability(
                propertyIDs: [.cameraRaw("Exposure2012")],
                feature: .basic,
                processVersionFamily: .process2012,
                level: .native,
                direction: .roundTrip,
                rendererEvidenceID: "test"
            ),
            XMPFeatureCapability(
                propertyIDs: [.cameraRaw("Exposure2012")],
                feature: .basic,
                processVersionFamily: .process2012,
                level: .native,
                direction: .roundTrip,
                rendererEvidenceID: "test"
            )
        ]))
    }
}
