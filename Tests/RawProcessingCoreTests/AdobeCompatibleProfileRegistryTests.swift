import XCTest
@testable import RawProcessingCore

final class AdobeCompatibleProfileRegistryTests: XCTestCase {
    func testAdobeColorMatchesReferenceSonyCameraWithVersionedApproximateFallback() throws {
        let descriptor = try XCTUnwrap(
            AdobeCompatibleProfileRegistry.descriptor(
                for: RawCameraProfileSelection(requestedName: " Adobe Color "),
                cameraMake: "SONY",
                cameraModel: "ILCE-6400"
            )
        )

        XCTAssertEqual(descriptor.sourceName, "Adobe Color")
        XCTAssertEqual(descriptor.cameraMatch, CameraMatch(make: "Sony", model: "ILCE-6400"))
        XCTAssertEqual(descriptor.fallbackID, "adobe-color-sony-ilce-6400")
        XCTAssertEqual(descriptor.fallbackVersion, 1)
        XCTAssertEqual(descriptor.compatibility, .approximate)
        XCTAssertTrue(descriptor.provenance.contains("LumaHarbor"))
    }

    func testAdobeStandardAliasResolvesCaseAndWhitespace() throws {
        let descriptor = try XCTUnwrap(
            AdobeCompatibleProfileRegistry.descriptor(
                for: RawCameraProfileSelection(requestedName: "  adobe standard  "),
                cameraMake: "Sony",
                cameraModel: "ILCE-6400"
            )
        )

        XCTAssertEqual(descriptor.sourceName, "Adobe Standard")
        XCTAssertEqual(descriptor.compatibility, .approximate)
    }

    func testKnownProfileOnUnknownCameraUsesNeutralFallbackWithoutApproximateClaim() throws {
        let descriptor = try XCTUnwrap(
            AdobeCompatibleProfileRegistry.descriptor(
                for: RawCameraProfileSelection(requestedName: "Adobe Color"),
                cameraMake: "Nikon",
                cameraModel: "Unknown"
            )
        )

        XCTAssertEqual(descriptor.compatibility, .preservedNotApplied)
        XCTAssertEqual(descriptor.fallbackID, "system-neutral-v1")
        XCTAssertEqual(descriptor.fallbackVersion, 1)
    }

    func testUnknownProfileIsPreservedButHasNoDescriptor() {
        XCTAssertNil(
            AdobeCompatibleProfileRegistry.descriptor(
                for: RawCameraProfileSelection(requestedName: "User DCP 42"),
                cameraMake: "SONY",
                cameraModel: "ILCE-6400"
            )
        )
    }
}
