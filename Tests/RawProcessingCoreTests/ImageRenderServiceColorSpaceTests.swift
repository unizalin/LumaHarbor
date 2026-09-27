import XCTest
@testable import RawProcessingCore

final class ImageRenderServiceColorSpaceTests: XCTestCase {
    func testServiceUsesTheRecipeWorkingSpaceRatherThanInferringFromTheCallSite() {
        let resolver = RawRenderRecipeResolver()
        let nativeRecipe = resolver.resolve(
            RawRenderRecipeInput(policy: .native),
            capabilities: RawDecoderCapabilities()
        )
        let persistedAdobeRecipe = resolver.resolve(
            RawRenderRecipeInput(
                policy: .adobeProcess2012V1,
                featureFlags: RawRendererFeatureFlags(adobeProcess2012V1Enabled: true)
            ),
            capabilities: RawDecoderCapabilities()
        )
        XCTAssertEqual(persistedAdobeRecipe.policy, .adobeProcess2012V1)
        XCTAssertEqual(persistedAdobeRecipe.effectivePolicy, .native)

        // Exercise the service's admitted-Adobe color-space branch without
        // weakening the resolver's default Gate 2 fail-closed behavior.
        let adobeRecipe = persistedAdobeRecipe.replacingEffectivePolicy(.adobeProcess2012V1)

        let native = ImageRenderService(preferMetal: false, recipe: nativeRecipe)
        let adobe = ImageRenderService(preferMetal: false, recipe: adobeRecipe)

        XCTAssertEqual(native.workingColorSpaceID, RawWorkingColorSpaceID.nativeExtendedLinearSRGBV1.rawValue)
        XCTAssertEqual(adobe.workingColorSpaceID, RawWorkingColorSpaceID.adobeCompatibleLinearWideGamutV1.rawValue)
        XCTAssertNotEqual(native.workingColorSpaceID, adobe.workingColorSpaceID)
        XCTAssertEqual(native.outputTransformID, RawOutputTransformID.displaySRGBV1.rawValue)
        XCTAssertEqual(adobe.outputTransformID, RawOutputTransformID.displaySRGBV1.rawValue)
    }

    func testReferenceRecipeSelectsTheSRGBOutputTransformForSixteenBitTIFF() {
        let recipe = RawRenderRecipeResolver().resolve(
            RawRenderRecipeInput(
                policy: .adobeProcess2012V1,
                featureFlags: RawRendererFeatureFlags(adobeProcess2012V1Enabled: true)
            ),
            capabilities: RawDecoderCapabilities()
        ).replacingOutputTransform(RawOutputTransformID.referenceTIFFSRGB16V1.rawValue)
        let service = ImageRenderService(preferMetal: false, recipe: recipe)

        XCTAssertEqual(service.outputTransformID, RawOutputTransformID.referenceTIFFSRGB16V1.rawValue)
        XCTAssertEqual(
            RawColorSpaceCatalog.outputColorSpace(for: service.outputTransformID).name as String?,
            CGColorSpace.sRGB as String
        )
    }
}
