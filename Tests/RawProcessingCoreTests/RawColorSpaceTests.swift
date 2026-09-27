import CoreGraphics
import XCTest
@testable import RawProcessingCore

final class RawColorSpaceTests: XCTestCase {
    func testVersionedWorkingSpaceIDsAreStableAndDistinct() {
        XCTAssertEqual(RawWorkingColorSpaceID.nativeExtendedLinearSRGBV1.rawValue, "extended-linear-srgb-v1")
        XCTAssertEqual(
            RawWorkingColorSpaceID.adobeCompatibleLinearWideGamutV1.rawValue,
            "adobe-compatible-linear-wide-gamut-v1"
        )
        XCTAssertNotEqual(
            RawColorSpaceCatalog.workingColorSpace(for: .nativeExtendedLinearSRGBV1).name,
            RawColorSpaceCatalog.workingColorSpace(for: .adobeCompatibleLinearWideGamutV1).name
        )
    }

    func testWorkingSpacesUseExtendedLinearTransferFunctions() {
        let native = RawColorSpaceCatalog.workingColorSpace(for: .nativeExtendedLinearSRGBV1)
        let adobe = RawColorSpaceCatalog.workingColorSpace(for: .adobeCompatibleLinearWideGamutV1)

        XCTAssertEqual(native.name as String?, CGColorSpace.extendedLinearSRGB as String)
        XCTAssertEqual(adobe.name as String?, CGColorSpace.extendedLinearDisplayP3 as String)
    }

    func testReferenceOutputTransformIsTaggedSRGB16() {
        XCTAssertEqual(RawOutputTransformID.referenceTIFFSRGB16V1.rawValue, "reference-tiff-srgb-16-v1")
        XCTAssertEqual(
            RawColorSpaceCatalog.outputColorSpace(for: .referenceTIFFSRGB16V1).name as String?,
            CGColorSpace.sRGB as String
        )
    }
}
