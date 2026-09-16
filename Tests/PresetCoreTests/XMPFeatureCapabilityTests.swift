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
