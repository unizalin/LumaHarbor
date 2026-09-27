import EditorCore
import RawProcessingCore
import XCTest

final class RawRenderDiagnosticsContractTests: XCTestCase {
    func testNativeAsShotRecipeUsesStableDiagnosticRows() {
        let recipe = makeRecipe(
            policy: .native,
            whiteBalance: RawWhiteBalanceRecipe(),
            cameraProfile: ResolvedRawCameraProfile()
        )

        let rows = RawRenderDiagnosticsPresenter.rows(for: recipe)

        XCTAssertEqual(
            rows.map(\.identifier),
            [
                "rawRender.mode",
                "rawRender.asShotWhiteBalance",
                "rawRender.requestedProfile",
                "rawRender.resolvedFallback",
                "rawRender.decoderFallback",
                "rawRender.metadataFallback",
            ]
        )
        XCTAssertEqual(rows[0].valueKey, "LumaHarbor Native")
        XCTAssertEqual(rows[1].valueKey, "As Shot")
        XCTAssertEqual(rows[2].valueKey, "None")
        XCTAssertEqual(rows[3].valueKey, "None")
        XCTAssertEqual(rows[4].valueKey, "None")
        XCTAssertEqual(rows[5].valueKey, "None")
    }

    func testAdobeRecipeReportsAdjustedWhiteBalanceAndPreservedProfile() {
        let recipe = makeRecipe(
            policy: .adobeProcess2012V1,
            effectivePolicy: .adobeProcess2012V1,
            whiteBalance: RawWhiteBalanceRecipe(temperatureOffsetKelvin: 125, tintOffset: -3),
            cameraProfile: ResolvedRawCameraProfile(
                requestedName: "Adobe Color",
                compatibility: .preservedNotApplied
            )
        )

        let rows = RawRenderDiagnosticsPresenter.rows(for: recipe)

        XCTAssertEqual(rows.first(where: { $0.identifier == "rawRender.mode" })?.valueKey, "Lightroom-compatible v1")
        XCTAssertEqual(rows.first(where: { $0.identifier == "rawRender.asShotWhiteBalance" })?.valueKey, "Adjusted")
        XCTAssertEqual(rows.first(where: { $0.identifier == "rawRender.requestedProfile" })?.literalValue, "Adobe Color")
        XCTAssertEqual(rows.first(where: { $0.identifier == "rawRender.resolvedFallback" })?.valueKey, "Profile Preserved, Not Applied")
    }

    func testFailClosedAdobePolicyReportsNativeExecutionMode() {
        let recipe = RawRenderRecipeResolver().resolve(
            RawRenderRecipeInput(policy: .adobeProcess2012V1),
            capabilities: RawDecoderCapabilities()
        )

        let rows = RawRenderDiagnosticsPresenter.rows(for: recipe)

        XCTAssertEqual(rows.first(where: { $0.identifier == "rawRender.mode" })?.valueKey, "LumaHarbor Native")
        XCTAssertEqual(recipe.policy, .adobeProcess2012V1)
        XCTAssertEqual(recipe.effectivePolicy, .native)
    }

    func testFallbackDiagnosticsAreVisibleWithoutExposingPrivateDetails() {
        let recipe = makeRecipe(
            policy: .native,
            cameraProfile: ResolvedRawCameraProfile(),
            diagnostics: [
                RawRenderDiagnostic(code: .rawDecoderVersionFallback, detail: "private-decoder-detail"),
                RawRenderDiagnostic(code: .metadataFallback, detail: "private-metadata-detail"),
            ]
        )

        let rows = RawRenderDiagnosticsPresenter.rows(for: recipe)

        XCTAssertEqual(rows.first(where: { $0.identifier == "rawRender.decoderFallback" })?.valueKey, "Fallback")
        XCTAssertEqual(rows.first(where: { $0.identifier == "rawRender.metadataFallback" })?.valueKey, "Fallback")
        XCTAssertTrue(rows.allSatisfy { $0.literalValue != "private-decoder-detail" && $0.literalValue != "private-metadata-detail" })
    }

    func testNilRecipeDoesNotRenderStaleDiagnostics() {
        XCTAssertTrue(RawRenderDiagnosticsPresenter.rows(for: nil).isEmpty)
    }

    private func makeRecipe(
        policy: RawRenderingCompatibility,
        effectivePolicy: RawRenderingCompatibility? = nil,
        whiteBalance: RawWhiteBalanceRecipe = RawWhiteBalanceRecipe(),
        cameraProfile: ResolvedRawCameraProfile,
        diagnostics: [RawRenderDiagnostic] = []
    ) -> ResolvedRawRenderRecipe {
        ResolvedRawRenderRecipe(
            policy: policy,
            effectivePolicy: effectivePolicy,
            decoder: RawDecoderRecipe(
                decoderIdentifier: DecoderIdentifier(kind: "coreImage", version: "system-default"),
                maximumPixelDimension: nil,
                draftModeEnabled: false
            ),
            whiteBalance: whiteBalance,
            lensCorrection: RawLensRecipe(mode: .off, profileID: nil, decoderEnabled: false),
            cameraProfile: cameraProfile,
            decoderOptionVectorID: "native-v1",
            workingColorSpaceID: "native-linear-sRGB-v1",
            outputTransformID: "display-sRGB-v1",
            diagnostics: diagnostics
        )
    }
}
