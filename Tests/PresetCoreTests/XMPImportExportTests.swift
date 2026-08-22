import XCTest
@testable import PresetCore
import RawProcessingCore

final class XMPImportExportTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "XMP")
        )
        return try Data(contentsOf: url)
    }

    // MARK: - Import preview: subset (spec §9.3 preview-first)

    func testSubsetPreviewClassifiesFieldsIntoNativeApproximateAndPreserved() throws {
        let preview = try XMPImporter().preview(data: try fixture("subset-basic.xmp"), suggestedName: "Fallback")
        XCTAssertEqual(preview.nativeFields.sorted(by: { $0.rawValue < $1.rawValue }), [.basicExposure, .basicTemperature, .basicTint])
        XCTAssertEqual(preview.approximateFields, [.basicContrast])
        // crs:WhiteBalance/HasSettings/PresetType/Version/ProcessVersion/Name
        // are administrative preset metadata, not adjustment data -- none of
        // them count as preserved (see `manifest.json`'s note for this fixture).
        XCTAssertEqual(preview.preservedProperties.count, 0)
        XCTAssertTrue(preview.hasApplicableAdjustments)
    }

    func testSubsetPreviewExtractsNameFromAltArray() throws {
        let preview = try XMPImporter().preview(data: try fixture("subset-basic.xmp"), suggestedName: "Fallback")
        XCTAssertEqual(preview.proposedPreset.name, "LumaHarbor Fixture Subset")
    }

    func testSubsetPreviewNeverWritesToDisk() throws {
        // `XMPImporter` never touches the filesystem -- there's no repository
        // in play at this layer -- so the only thing to assert is that
        // repeated preview calls are pure and side-effect free.
        let first = try XMPImporter().preview(data: try fixture("subset-basic.xmp"), suggestedName: "Fallback")
        let second = try XMPImporter().preview(data: try fixture("subset-basic.xmp"), suggestedName: "Fallback")
        XCTAssertEqual(first.nativeFields, second.nativeFields)
        XCTAssertEqual(first.proposedPreset.patch, second.proposedPreset.patch)
    }

    func testNameFallsBackToSuggestedNameWhenNoAltArrayPresent() throws {
        let xml = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
          crs:ProcessVersion="15.4" crs:Exposure2012="+0.5"/>
        </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        let preview = try XMPImporter().preview(data: Data(xml.utf8), suggestedName: "My Suggested Name")
        XCTAssertEqual(preview.proposedPreset.name, "My Suggested Name")
    }

    // MARK: - Import preview: full basic/HSL/curve fixture

    func testFullFixturePreviewCoversEveryCategory() throws {
        let preview = try XMPImporter().preview(data: try fixture("basic-hsl-curve.xmp"), suggestedName: "Fallback")
        // 3 native basic + 2 contextual white balance + 24 HSL + 5 split
        // toning + 1 tone curve (special-cased, spec §7's own table).
        XCTAssertEqual(preview.nativeFields.count, 35)
        XCTAssertTrue(preview.nativeFields.contains(.advancedToneCurve))
        // 5 approximate basic + 2 sharpening + 4 vignette + 3 grain.
        XCTAssertEqual(preview.approximateFields.count, 14)
        // SharpenDetail, SharpenEdgeMasking, LuminanceSmoothing,
        // ColorNoiseReduction, CameraProfile.
        XCTAssertEqual(preview.preservedProperties.count, 5)
        XCTAssertTrue(preview.preservedProperties.contains(.cameraRaw("SharpenDetail")))
        XCTAssertTrue(preview.preservedProperties.contains(.cameraRaw("CameraProfile")))
    }

    func testFullFixtureImportsCorrectBasicValues() throws {
        let preview = try XMPImporter().preview(data: try fixture("basic-hsl-curve.xmp"), suggestedName: "Fallback")
        let basic = try XCTUnwrap(preview.proposedPreset.patch.basic)
        XCTAssertEqual(basic.exposure, 0.75)
        XCTAssertEqual(basic.temperature, 5500)
        XCTAssertEqual(basic.tint, 11)
        XCTAssertEqual(basic.contrast, 15)
        XCTAssertEqual(basic.vibrance, 20)
        XCTAssertEqual(basic.saturation, -5)
    }

    func testFullFixtureImportsAllEightHSLBands() throws {
        let preview = try XMPImporter().preview(data: try fixture("basic-hsl-curve.xmp"), suggestedName: "Fallback")
        let hsl = try XCTUnwrap(preview.proposedPreset.patch.hsl)
        XCTAssertEqual(hsl.red, HSLBandPatch(hue: -20, saturation: 15, luminance: -5))
        XCTAssertEqual(hsl.orange, HSLBandPatch(hue: 5, saturation: -10, luminance: 10))
        XCTAssertEqual(hsl.yellow, HSLBandPatch(hue: 10, saturation: 20, luminance: -15))
        XCTAssertEqual(hsl.green, HSLBandPatch(hue: -5, saturation: -20, luminance: 5))
        XCTAssertEqual(hsl.aqua, HSLBandPatch(hue: 15, saturation: 10, luminance: -10))
        XCTAssertEqual(hsl.blue, HSLBandPatch(hue: -10, saturation: 5, luminance: 20))
        XCTAssertEqual(hsl.purple, HSLBandPatch(hue: 20, saturation: -5, luminance: -20))
        XCTAssertEqual(hsl.magenta, HSLBandPatch(hue: -15, saturation: -15, luminance: 15))
    }

    func testFullFixtureImportsSplitToningSharpeningVignetteAndGrain() throws {
        let preview = try XMPImporter().preview(data: try fixture("basic-hsl-curve.xmp"), suggestedName: "Fallback")
        let patch = preview.proposedPreset.patch
        XCTAssertEqual(patch.splitToning, SplitToningPatch(shadowHue: 210, shadowSaturation: 15, highlightHue: 50, highlightSaturation: 10, balance: -5))
        XCTAssertEqual(patch.sharpening?.amount, 60) // Sharpness 40 * 1.5
        XCTAssertEqual(patch.sharpening?.radius, 1)
        XCTAssertNil(patch.sharpening?.detail) // preserved, never mapped
        XCTAssertNil(patch.sharpening?.masking) // preserved, never mapped
        XCTAssertEqual(patch.vignette, VignettePatch(amount: -25, midpoint: 50, roundness: 0, feather: 50))
        XCTAssertEqual(patch.grain, GrainPatch(amount: 25, size: 25, roughness: 50))
    }

    func testFullFixtureImportsToneCurve() throws {
        let preview = try XMPImporter().preview(data: try fixture("basic-hsl-curve.xmp"), suggestedName: "Fallback")
        let curve = try XCTUnwrap(preview.proposedPreset.patch.advancedToneCurve)
        let expected: [ToneCurvePoint] = [
            ToneCurvePoint(x: 0, y: 0),
            ToneCurvePoint(x: 64.0 / 255, y: 80.0 / 255),
            ToneCurvePoint(x: 192.0 / 255, y: 176.0 / 255),
            ToneCurvePoint(x: 1, y: 1)
        ]
        XCTAssertEqual(curve.points, expected)
    }

    // MARK: - Unsupported (legacy) process version

    func testUnsupportedProcessVersionPreservesEverythingAndAppliesNothing() throws {
        let preview = try XMPImporter().preview(data: try fixture("unsupported-process-version.xmp"), suggestedName: "Fallback")
        XCTAssertTrue(preview.nativeFields.isEmpty)
        XCTAssertTrue(preview.approximateFields.isEmpty)
        XCTAssertEqual(preview.preservedProperties.count, 2)
        XCTAssertTrue(preview.preservedProperties.contains(.cameraRaw("Exposure2012")))
        XCTAssertTrue(preview.preservedProperties.contains(.cameraRaw("Contrast2012")))
        XCTAssertFalse(preview.hasApplicableAdjustments)
    }

    func testUnsupportedProcessVersionEmitsUnknownProcessVersionDiagnostic() throws {
        let preview = try XMPImporter().preview(data: try fixture("unsupported-process-version.xmp"), suggestedName: "Fallback")
        XCTAssertTrue(preview.diagnostics.contains {
            $0.code == "unknownProcessVersion" && $0.detail == "5.0"
        })
    }

    func testUnsupportedProcessVersionStillProducesADormantPreset() throws {
        // Spec §9.3: no applicable adjustments is a valid outcome, not an
        // error -- the caller can still save it to keep the original data.
        let preview = try XMPImporter().preview(data: try fixture("unsupported-process-version.xmp"), suggestedName: "Fallback")
        XCTAssertTrue(preview.proposedPreset.patch.isEmpty)
        XCTAssertNotNil(preview.proposedPreset.xmpEnvelope)
    }

    // MARK: - Document kind rejection

    func testRejectsDocumentWithNoCameraRawProperties() throws {
        let xml = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/" dc:format="image/x-sony-arw"/>
        </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        XCTAssertThrowsError(try XMPImporter().preview(data: Data(xml.utf8), suggestedName: "Fallback")) {
            guard case .unsupportedDocumentKind = $0 as? PresetError else {
                return XCTFail("Expected .unsupportedDocumentKind, got \($0)")
            }
        }
    }

    // MARK: - Malformed individual values don't abort the whole import

    func testMalformedScalarValueFallsBackToPreservedWithDiagnostic() throws {
        let xml = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
          crs:ProcessVersion="15.4" crs:Exposure2012="not-a-number" crs:Vibrance="+10"/>
        </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        let preview = try XMPImporter().preview(data: Data(xml.utf8), suggestedName: "Fallback")
        XCTAssertEqual(preview.nativeFields, [.basicVibrance])
        XCTAssertTrue(preview.preservedProperties.contains(.cameraRaw("Exposure2012")))
        XCTAssertTrue(preview.diagnostics.contains { $0.code == "malformedPropertyValue" && $0.propertyID == .cameraRaw("Exposure2012") })
        XCTAssertNil(preview.proposedPreset.patch.basic?.exposure)
    }

    func testMalformedToneCurveFallsBackToPreservedWithDiagnostic() throws {
        let xml = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
          crs:ProcessVersion="15.4" crs:Exposure2012="+0.5">
          <crs:ToneCurvePV2012>
           <rdf:Seq>
            <rdf:li>not-a-point</rdf:li>
           </rdf:Seq>
          </crs:ToneCurvePV2012>
        </rdf:Description>
        </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        let preview = try XMPImporter().preview(data: Data(xml.utf8), suggestedName: "Fallback")
        XCTAssertNil(preview.proposedPreset.patch.advancedToneCurve)
        XCTAssertTrue(preview.preservedProperties.contains(.cameraRaw("ToneCurvePV2012")))
        XCTAssertTrue(preview.diagnostics.contains { $0.code == "malformedToneCurve" })
    }

    // MARK: - Export: preserves unmapped/unknown data (spec §9.4)

    func testExportOfXMPImportedPresetPreservesUnknownNestedRDF() throws {
        let preview = try XMPImporter().preview(data: try fixture("unknown-nested-rdf.xmp"), suggestedName: "Fallback")
        let result = try XMPExporter().export(preview.proposedPreset)
        let reparsed = try XMPCodec().parse(result.data)

        guard case .structure(let maskTree)? = reparsed.property(namespaceURI: "urn:test:future", localName: "MaskTree") else {
            return XCTFail("Expected future:MaskTree to survive export")
        }
        XCTAssertEqual(maskTree[XMPPropertyID(namespaceURI: "urn:test:future", localName: "kind")], .text("radial"))

        guard case .array(let kind, let values)? = reparsed.property(namespaceURI: "urn:test:future", localName: "Tags") else {
            return XCTFail("Expected future:Tags to survive export")
        }
        XCTAssertEqual(kind, .bag)
        XCTAssertEqual(values.count, 2)
        XCTAssertTrue(values.contains(.text("portrait")))
        XCTAssertTrue(values.contains(.text("studio")))
    }

    func testExportOfXMPImportedPresetKeepsMappedFieldsInSync() throws {
        let preview = try XMPImporter().preview(data: try fixture("unknown-nested-rdf.xmp"), suggestedName: "Fallback")
        var preset = preview.proposedPreset
        preset.patch.basic?.exposure = 1.0 // simulate a user edit in LumaHarbor
        let result = try XMPExporter().export(preset)
        let reparsed = try XMPCodec().parse(result.data)
        XCTAssertEqual(reparsed.property(namespaceURI: XMPNamespace.cameraRaw, localName: "Exposure2012"), .text("1"))
    }

    // MARK: - Export: full basic/HSL/curve fixture round-trips every mapped field

    func testExportOfFullFixtureRoundTripsAllScalarLeavesSemantically() throws {
        let preview = try XMPImporter().preview(data: try fixture("basic-hsl-curve.xmp"), suggestedName: "Fallback")
        let context = PresetApplicationContext(baselineTemperatureKelvin: 0, baselineTint: 0)
        let result = try XMPExporter().export(preview.proposedPreset, context: context)
        let reexported = try XMPImporter().preview(data: result.data, suggestedName: "Fallback")

        XCTAssertEqual(reexported.proposedPreset.patch.basic?.exposure, 0.75)
        XCTAssertEqual(reexported.proposedPreset.patch.basic?.contrast, 15)
        XCTAssertEqual(reexported.proposedPreset.patch.hsl?.red, HSLBandPatch(hue: -20, saturation: 15, luminance: -5))
        XCTAssertEqual(reexported.proposedPreset.patch.splitToning?.balance, -5)
        XCTAssertEqual(reexported.proposedPreset.patch.sharpening?.amount, 60)
        XCTAssertEqual(reexported.proposedPreset.patch.vignette?.amount, -25)
        XCTAssertEqual(reexported.proposedPreset.patch.grain?.roughness, 50)
        XCTAssertEqual(reexported.proposedPreset.patch.advancedToneCurve, preview.proposedPreset.patch.advancedToneCurve)
    }

    // MARK: - Export: white balance is source- and context-dependent (spec §7)

    func testExportOfAdobeSourcedWhiteBalanceIsAbsoluteRegardlessOfContext() throws {
        let preview = try XMPImporter().preview(data: try fixture("subset-basic.xmp"), suggestedName: "Fallback")
        let result = try XMPExporter().export(preview.proposedPreset, context: .none)
        let reparsed = try XMPCodec().parse(result.data)
        XCTAssertEqual(reparsed.property(namespaceURI: XMPNamespace.cameraRaw, localName: "Temperature"), .text("5500"))
        XCTAssertEqual(reparsed.property(namespaceURI: XMPNamespace.cameraRaw, localName: "Tint"), .text("11"))
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func testExportOfNativeSourcedWhiteBalanceWithoutBaselineFlagsReverseMappingUnavailable() throws {
        let preset = PresetDocument(
            name: "Native WB",
            source: .native,
            patch: AdjustmentPatch(basic: BasicAdjustmentPatch(temperature: 10, tint: -5))
        )
        let result = try XMPExporter().export(preset, context: .none)
        XCTAssertTrue(result.diagnostics.contains { $0.code == "reverseMappingUnavailable" && $0.propertyID == .cameraRaw("Temperature") })
        XCTAssertTrue(result.diagnostics.contains { $0.code == "reverseMappingUnavailable" && $0.propertyID == .cameraRaw("Tint") })
        let reparsed = try XMPCodec().parse(result.data)
        XCTAssertNil(reparsed.property(namespaceURI: XMPNamespace.cameraRaw, localName: "Temperature"))
    }

    func testExportOfNativeSourcedWhiteBalanceWithBaselineConvertsToAbsolute() throws {
        let preset = PresetDocument(
            name: "Native WB",
            source: .native,
            patch: AdjustmentPatch(basic: BasicAdjustmentPatch(temperature: 10, tint: -4))
        )
        let context = PresetApplicationContext(baselineTemperatureKelvin: 5000, baselineTint: 0)
        let result = try XMPExporter().export(preset, context: context)
        let reparsed = try XMPCodec().parse(result.data)
        // 5000 + 10 * 45 (kelvinPerTemperatureUnit)
        XCTAssertEqual(reparsed.property(namespaceURI: XMPNamespace.cameraRaw, localName: "Temperature"), .text("5450"))
        // 0 + -4 * 1.5 (tintPerUnit)
        XCTAssertEqual(reparsed.property(namespaceURI: XMPNamespace.cameraRaw, localName: "Tint"), .text("-6"))
        XCTAssertEqual(reparsed.property(namespaceURI: XMPNamespace.cameraRaw, localName: "WhiteBalance"), .text("Custom"))
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    // MARK: - Export: fields with no reverse mapping are flagged, not silently dropped

    func testExportFlagsFieldsWithNoReverseMappingAtAll() throws {
        // `noiseReduction` leaves have no registry entry in either direction
        // (spec §7: independent luminance/color noise reduction stays
        // preserved-only) -- exporting one must surface a diagnostic rather
        // than silently doing nothing.
        let preset = PresetDocument(
            name: "No Reverse Mapping",
            source: .native,
            patch: AdjustmentPatch(noiseReduction: NoiseReductionPatch(luminanceAmount: 20))
        )
        let result = try XMPExporter().export(preset)
        XCTAssertTrue(result.diagnostics.contains { $0.code == "reverseMappingUnavailable" && $0.detail == AdjustmentFieldID.noiseReductionLuminanceAmount.rawValue })
    }

    // MARK: - Native-sourced preset with no prior envelope exports from scratch

    func testExportOfNativePresetWithNoEnvelopeStillProducesValidXMP() throws {
        let preset = PresetDocument(
            name: "Pure Native",
            source: .native,
            patch: AdjustmentPatch(basic: BasicAdjustmentPatch(exposure: 0.3, saturation: 10))
        )
        let result = try XMPExporter().export(preset)
        let reparsed = try XMPCodec().parse(result.data)
        XCTAssertEqual(reparsed.property(namespaceURI: XMPNamespace.cameraRaw, localName: "Exposure2012"), .text("0.3"))
        XCTAssertEqual(reparsed.property(namespaceURI: XMPNamespace.cameraRaw, localName: "Saturation"), .text("10"))
    }

    // MARK: - Non-UTF-8 source XMP round-trips without losing data (finding #3)
    //
    // A hardcoded `.utf8` decode of the source bytes used to turn any
    // legitimately non-UTF-8-encoded `.xmp` (real Adobe tooling can emit
    // UTF-16) into an empty `originalPacketUTF8`, and `XMPExporter`'s
    // `baseDocument(for:)` falls back to a blank document when it can't
    // reparse that -- silently losing every unmapped/preserved property on
    // export. These lock in the fix: import must retain the *full* packet
    // regardless of source encoding, and export from that preset must still
    // carry unmapped data through.

    private func utf16Data(_ xml: String, bigEndian: Bool) -> Data {
        let bom: [UInt8] = bigEndian ? [0xFE, 0xFF] : [0xFF, 0xFE]
        let body = xml.data(using: bigEndian ? .utf16BigEndian : .utf16LittleEndian)!
        return Data(bom) + body
    }

    private func utf16FixtureXML() -> String {
        """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about=""
          xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
          xmlns:future="urn:test:future"
          crs:ProcessVersion="15.4"
          crs:Exposure2012="+0.25">
         <future:Tags>
          <rdf:Bag>
           <rdf:li>portrait</rdf:li>
           <rdf:li>studio</rdf:li>
          </rdf:Bag>
         </future:Tags>
        </rdf:Description>
        </rdf:RDF>
        </x:xmpmeta>
        """
    }

    func testImportOfUTF16DocumentRetainsFullOriginalPacketNotAnEmptyString() throws {
        let data = utf16Data(utf16FixtureXML(), bigEndian: true)
        let preview = try XMPImporter().preview(data: data, suggestedName: "Fallback")
        let packet = try XCTUnwrap(preview.proposedPreset.xmpEnvelope?.originalPacketUTF8)
        XCTAssertFalse(packet.isEmpty)
        XCTAssertTrue(packet.contains("crs:Exposure2012"))
        // `future:` is *not* a well-known prefix, so the round-2 fix's
        // re-serialized canonical packet is free to rename it (spec §6.1:
        // namespace prefix literal values aren't part of "lossless") --
        // the property (namespace URI `urn:test:future` + local name
        // `Tags`) must still be present, just checked semantically rather
        // than via a literal prefix string.
        let reparsed = try XMPCodec().parse(Data(packet.utf8))
        XCTAssertNotNil(reparsed.property(namespaceURI: "urn:test:future", localName: "Tags"))
    }

    func testExportOfUTF16ImportedPresetPreservesUnknownPropertyAndMappedField() throws {
        for bigEndian in [false, true] {
            let data = utf16Data(utf16FixtureXML(), bigEndian: bigEndian)
            let preview = try XMPImporter().preview(data: data, suggestedName: "Fallback")
            XCTAssertEqual(preview.proposedPreset.patch.basic?.exposure, 0.25)

            let result = try XMPExporter().export(preview.proposedPreset)
            let reparsed = try XMPCodec().parse(result.data)

            XCTAssertEqual(
                reparsed.property(namespaceURI: XMPNamespace.cameraRaw, localName: "Exposure2012"), .text("0.25")
            )
            guard case .array(let kind, let values)? = reparsed.property(namespaceURI: "urn:test:future", localName: "Tags") else {
                XCTFail("Expected future:Tags to survive export from a UTF-16 (bigEndian: \(bigEndian))-sourced XMP")
                continue
            }
            XCTAssertEqual(kind, .bag)
            XCTAssertEqual(values.count, 2)
            XCTAssertTrue(values.contains(.text("portrait")))
            XCTAssertTrue(values.contains(.text("studio")))
        }
    }

    // MARK: - A source XML declaration must not survive into the stored
    // envelope and later contradict it (finding #2, round 2)
    //
    // Round 1's fix decoded non-UTF-8 source bytes into a `String` and
    // stored that `String` (re-encoded `.utf8`) verbatim as
    // `originalPacketUTF8`. That's correct when the source has no `<?xml
    // ... encoding="..."?>` declaration (the fixture above), but when it
    // does, the decoded `String` still contains that declaration as
    // literal text -- so the *stored* bytes are genuinely UTF-8 while the
    // text embedded in them still claims e.g. `encoding="UTF-16LE"`.
    // `XMPExporter.baseDocument(for:)` re-parses that mismatched pair,
    // `XMLParser` fails on it, and every unmapped/preserved property is
    // lost on export exactly as round 1 was written to prevent -- just via
    // a different mismatch this time. These fixtures include the
    // declaration `utf16FixtureXML()` above omits, so they reproduce
    // *this* gap specifically.

    private func utf16FixtureXMLWithDeclaration(encodingName: String) -> String {
        "<?xml version=\"1.0\" encoding=\"\(encodingName)\"?>\n" + utf16FixtureXML()
    }

    func testImportOfUTF16DocumentWithXMLDeclarationRetainsFullOriginalPacketNotAnEmptyString() throws {
        let data = utf16Data(utf16FixtureXMLWithDeclaration(encodingName: "UTF-16BE"), bigEndian: true)
        let preview = try XMPImporter().preview(data: data, suggestedName: "Fallback")
        let packet = try XCTUnwrap(preview.proposedPreset.xmpEnvelope?.originalPacketUTF8)
        XCTAssertFalse(packet.isEmpty)
        XCTAssertTrue(packet.contains("crs:Exposure2012"))
        // See the comment on the no-declaration variant above: `future:`
        // isn't a well-known prefix, so it's checked semantically.
        let reparsed = try XMPCodec().parse(Data(packet.utf8))
        XCTAssertNotNil(reparsed.property(namespaceURI: "urn:test:future", localName: "Tags"))
    }

    func testExportOfUTF16WithXMLDeclarationImportedPresetPreservesMappedFieldAndUnknownNestedRDF() throws {
        for bigEndian in [false, true] {
            let encodingName = bigEndian ? "UTF-16BE" : "UTF-16LE"
            let data = utf16Data(utf16FixtureXMLWithDeclaration(encodingName: encodingName), bigEndian: bigEndian)
            let preview = try XMPImporter().preview(data: data, suggestedName: "Fallback")
            XCTAssertEqual(preview.proposedPreset.patch.basic?.exposure, 0.25, "encodingName: \(encodingName)")

            let result = try XMPExporter().export(preview.proposedPreset)
            let reparsed = try XMPCodec().parse(result.data)

            XCTAssertEqual(
                reparsed.property(namespaceURI: XMPNamespace.cameraRaw, localName: "Exposure2012"), .text("0.25"),
                "encodingName: \(encodingName)"
            )
            guard case .array(let kind, let values)? = reparsed.property(namespaceURI: "urn:test:future", localName: "Tags") else {
                XCTFail("Expected future:Tags (unknown nested RDF) to survive export from a declared-\(encodingName) XMP")
                continue
            }
            XCTAssertEqual(kind, .bag, "encodingName: \(encodingName)")
            XCTAssertEqual(values.count, 2, "encodingName: \(encodingName)")
            XCTAssertTrue(values.contains(.text("portrait")))
            XCTAssertTrue(values.contains(.text("studio")))
        }
    }

    /// The fix stores a re-serialized canonical packet rather than the
    /// source text verbatim, and `XMPSerializer` never emits an `<?xml
    /// ... encoding="..."?>` declaration at all -- so the stored envelope
    /// can never disagree with its own (always-UTF-8) bytes, regardless of
    /// what the source document declared.
    func testStoredEnvelopePacketNeverContainsAnEncodingDeclarationThatCouldContradictItsUTF8Bytes() throws {
        for bigEndian in [false, true] {
            let encodingName = bigEndian ? "UTF-16BE" : "UTF-16LE"
            let data = utf16Data(utf16FixtureXMLWithDeclaration(encodingName: encodingName), bigEndian: bigEndian)
            let preview = try XMPImporter().preview(data: data, suggestedName: "Fallback")
            let packet = try XCTUnwrap(preview.proposedPreset.xmpEnvelope?.originalPacketUTF8)
            XCTAssertFalse(packet.contains("encoding="), "encodingName: \(encodingName), packet: \(packet.prefix(80))")
            // And it must still be genuinely re-parseable as the UTF-8 it's
            // stored as -- not just "doesn't mention an encoding", but
            // actually round-trips.
            XCTAssertNoThrow(try XMPCodec().parse(Data(packet.utf8)), "encodingName: \(encodingName)")
        }
    }
}
