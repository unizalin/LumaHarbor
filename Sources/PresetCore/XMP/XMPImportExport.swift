import Foundation
import RawProcessingCore

/// The result of parsing and classifying one `.xmp` develop preset, before
/// anything is written to a repository (spec §9.3: import is preview-first).
public struct XMPImportPreview: Equatable, Sendable {
    public var proposedPreset: PresetDocument
    public var nativeFields: [AdjustmentFieldID]
    public var approximateFields: [AdjustmentFieldID]
    public var preservedProperties: [XMPPropertyID]
    public var diagnostics: [XMPDiagnostic]

    /// Spec §9.3: "no applicable adjustments yet" is a valid, non-error
    /// outcome the UI must label explicitly, not silently drop.
    public var hasApplicableAdjustments: Bool { !nativeFields.isEmpty || !approximateFields.isEmpty }
}

/// Parses a Camera Raw develop preset `.xmp` into an `XMPImportPreview`.
/// Never writes anything -- spec §9.3, the caller decides what to keep
/// (including which approximate leaves to drop) before persisting.
public struct XMPImporter: Sendable {
    private let registry: XMPMappingRegistry
    private let codec: XMPCodec

    public init(registry: XMPMappingRegistry = .default, codec: XMPCodec = XMPCodec()) {
        self.registry = registry
        self.codec = codec
    }

    /// Namespace-qualified administrative/metadata properties that describe
    /// the document itself rather than an adjustment -- recognised so they
    /// don't inflate the "preserved" count with noise the user can't act on.
    private static let administrativeProperties: Set<XMPPropertyID> = [
        .cameraRaw("Version"), .cameraRaw("ProcessVersion"), .cameraRaw("WhiteBalance"),
        .cameraRaw("HasSettings"), .cameraRaw("PresetType"), .cameraRaw("Name"),
        .cameraRaw("Group"), .cameraRaw("UUID"), .cameraRaw("SupportsAmount2"),
        .cameraRaw("SupportsColor"), .cameraRaw("SupportsMonochrome"), .cameraRaw("SupportsHighDynamicRange")
    ]

    public func preview(data: Data, suggestedName: String) throws -> XMPImportPreview {
        let document = try codec.parse(data)
        let hasCameraRawProperties = document.properties.keys.contains { $0.namespaceURI == XMPNamespace.cameraRaw }
        guard hasCameraRawProperties else {
            throw PresetError.unsupportedDocumentKind("no Camera Raw settings found")
        }

        let processVersion: String? = {
            if case .text(let value)? = document.property(namespaceURI: XMPNamespace.cameraRaw, localName: "ProcessVersion") {
                return value
            }
            return nil
        }()
        let isRecognizedProcessVersion = XMPMappingRegistry.isRecognizedProcessVersion(processVersion)

        var diagnostics: [XMPDiagnostic] = []
        var nativeFields: [AdjustmentFieldID] = []
        var approximateFields: [AdjustmentFieldID] = []
        var preservedProperties: [XMPPropertyID] = []
        var mappedProperties: Set<XMPPropertyID> = []
        var builder = AdjustmentPatchBuilder()

        if !isRecognizedProcessVersion {
            diagnostics.append(XMPDiagnostic(
                severity: .warning,
                code: "unknownProcessVersion",
                propertyID: .cameraRaw("ProcessVersion"),
                detail: processVersion ?? "missing"
            ))
        }

        let sortedProperties = document.properties.sorted { lhs, rhs in
            (lhs.key.namespaceURI, lhs.key.localName) < (rhs.key.namespaceURI, rhs.key.localName)
        }

        for (id, value) in sortedProperties {
            if id.namespaceURI == XMPNamespace.rdf, id.localName == "about" { continue }
            if Self.administrativeProperties.contains(id) { continue }

            guard isRecognizedProcessVersion else {
                preservedProperties.append(id)
                continue
            }

            if id == .cameraRaw("ToneCurvePV2012") {
                do {
                    builder.advancedToneCurve = try Self.importToneCurve(value)
                    nativeFields.append(.advancedToneCurve)
                    mappedProperties.insert(id)
                } catch {
                    diagnostics.append(XMPDiagnostic(severity: .warning, code: "malformedToneCurve", propertyID: id))
                    preservedProperties.append(id)
                }
                continue
            }

            guard let mapping = registry.mapping(for: id) else {
                preservedProperties.append(id)
                continue
            }

            do {
                let scalar = try mapping.importScalar(value)
                builder.set(mapping.field, to: scalar)
                mappedProperties.insert(id)
                switch mapping.level {
                case .native: nativeFields.append(mapping.field)
                case .approximate: approximateFields.append(mapping.field)
                case .preserved: preservedProperties.append(id)
                }
            } catch {
                diagnostics.append(XMPDiagnostic(severity: .warning, code: "malformedPropertyValue", propertyID: id))
                preservedProperties.append(id)
            }
        }

        // Round 1 fixed a hardcoded `.utf8` decode that silently turned a
        // legitimate non-UTF-8 `.xmp` into an empty `originalPacketUTF8`.
        // That fix (decoding with the sniffed source encoding) introduced a
        // *different* loss: the decoded `String` still contains the
        // original document's own `<?xml ... encoding="UTF-16"?>`
        // declaration as literal text, so re-encoding it `.utf8` for
        // storage produces bytes that are genuinely UTF-8 while the
        // embedded declaration still claims UTF-16 -- `baseDocument(for:)`
        // below re-parses that mismatched pair, `XMLParser` fails on it,
        // and every unmapped/preserved property is lost exactly as before,
        // just via a different mismatch. Serializing the document graph
        // *already parsed above* back through the same codec sidesteps
        // this entirely: `XMPSerializer.serialize` never emits an
        // `encoding` declaration at all, so what's stored here is
        // self-consistent UTF-8 with nothing left to disagree about, and
        // is exactly the "canonical UTF-8 packet" the round-trip contract
        // calls for (spec §6.1: semantically lossless, not byte-for-byte).
        // A failure here throws rather than silently degrading to an empty
        // envelope, since `document` is already known-valid at this point.
        let originalPacketData = try codec.serialize(document)
        guard let originalPacketUTF8 = String(data: originalPacketData, encoding: .utf8) else {
            throw PresetError.malformedXML("could not encode the canonical packet as UTF-8")
        }
        let envelope = XMPEnvelope(
            originalPacketUTF8: originalPacketUTF8,
            documentKind: .developPreset,
            processVersion: processVersion,
            mappedProperties: mappedProperties,
            diagnostics: diagnostics
        )
        let proposedPreset = PresetDocument(
            name: Self.extractName(from: document) ?? suggestedName,
            source: .adobeXMP(tool: nil, version: processVersion),
            patch: builder.build(),
            xmpEnvelope: envelope
        )

        return XMPImportPreview(
            proposedPreset: proposedPreset,
            nativeFields: nativeFields,
            approximateFields: approximateFields,
            preservedProperties: preservedProperties,
            diagnostics: diagnostics
        )
    }

    /// `crs:Name` is an `rdf:Alt` of language alternatives (spec fixture
    /// `subset-basic.xmp`); this takes the first alternative regardless of
    /// `xml:lang`; Phase 1 has no locale-aware preset naming.
    private static func extractName(from document: XMPDocument) -> String? {
        guard case .array(_, let values)? = document.property(namespaceURI: XMPNamespace.cameraRaw, localName: "Name"),
              let first = values.first else { return nil }
        switch first {
        case .text(let text): return text.isEmpty ? nil : text
        case .qualified(.text(let text), _): return text.isEmpty ? nil : text
        default: return nil
        }
    }

    /// `crs:ToneCurvePV2012` is an `rdf:Seq` of `"x, y"` text pairs on a
    /// 0...255 scale (Adobe/exiv2 reference); LumaHarbor's curve is
    /// normalised to 0...1.
    static func importToneCurve(_ value: XMPValue) throws -> AdvancedToneCurve {
        guard case .array(_, let values) = value else {
            throw PresetError.malformedXML("expected an rdf:Seq for ToneCurvePV2012")
        }
        var points: [ToneCurvePoint] = []
        points.reserveCapacity(values.count)
        for item in values {
            guard case .text(let text) = item else {
                throw PresetError.malformedXML("expected a text point in ToneCurvePV2012")
            }
            let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]), x.isFinite, y.isFinite else {
                // A fixed, safe message -- never a fragment of the untrusted
                // XMP value itself (spec §6.2/§11: no raw XMP in errors).
                throw PresetError.malformedXML("malformed ToneCurvePV2012 point")
            }
            points.append(ToneCurvePoint(x: x / 255, y: y / 255))
        }
        return AdvancedToneCurve(points: points)
    }

    /// Inverse of `importToneCurve`, rounding back to integers the way Adobe
    /// itself writes them.
    static func exportToneCurve(_ curve: AdvancedToneCurve) -> XMPValue {
        let items: [XMPValue] = curve.points.map { point in
            let x = Int((point.x * 255).rounded())
            let y = Int((point.y * 255).rounded())
            return .text("\(x), \(y)")
        }
        return .array(kind: .seq, values: items)
    }
}

/// Accumulates scalar leaves by `AdjustmentFieldID` while importing, then
/// produces one canonicalized `AdjustmentPatch`. Kept separate from
/// `AdjustmentPatch` itself so the importer can set leaves one at a time
/// without threading eight separate `inout` nested-patch parameters through
/// every call site.
struct AdjustmentPatchBuilder {
    var basic = BasicAdjustmentPatch()
    var advancedToneCurve: AdvancedToneCurve?
    var hsl = HSLAdjustmentPatch()
    var splitToning = SplitToningPatch()
    var sharpening = SharpeningPatch()
    var vignette = VignettePatch()
    var grain = GrainPatch()

    mutating func set(_ field: AdjustmentFieldID, to value: Double) {
        switch field {
        case .basicExposure: basic.exposure = value
        case .basicTemperature: basic.temperature = value
        case .basicTint: basic.tint = value
        case .basicContrast: basic.contrast = value
        case .basicHighlights: basic.highlights = value
        case .basicShadows: basic.shadows = value
        case .basicWhites: basic.whites = value
        case .basicBlacks: basic.blacks = value
        case .basicVibrance: basic.vibrance = value
        case .basicSaturation: basic.saturation = value
        case .advancedToneCurve: break // whole-value leaf, set directly on `advancedToneCurve`
        case .hslRedHue: hsl.red = (hsl.red ?? HSLBandPatch()).setting(\.hue, value)
        case .hslRedSaturation: hsl.red = (hsl.red ?? HSLBandPatch()).setting(\.saturation, value)
        case .hslRedLuminance: hsl.red = (hsl.red ?? HSLBandPatch()).setting(\.luminance, value)
        case .hslOrangeHue: hsl.orange = (hsl.orange ?? HSLBandPatch()).setting(\.hue, value)
        case .hslOrangeSaturation: hsl.orange = (hsl.orange ?? HSLBandPatch()).setting(\.saturation, value)
        case .hslOrangeLuminance: hsl.orange = (hsl.orange ?? HSLBandPatch()).setting(\.luminance, value)
        case .hslYellowHue: hsl.yellow = (hsl.yellow ?? HSLBandPatch()).setting(\.hue, value)
        case .hslYellowSaturation: hsl.yellow = (hsl.yellow ?? HSLBandPatch()).setting(\.saturation, value)
        case .hslYellowLuminance: hsl.yellow = (hsl.yellow ?? HSLBandPatch()).setting(\.luminance, value)
        case .hslGreenHue: hsl.green = (hsl.green ?? HSLBandPatch()).setting(\.hue, value)
        case .hslGreenSaturation: hsl.green = (hsl.green ?? HSLBandPatch()).setting(\.saturation, value)
        case .hslGreenLuminance: hsl.green = (hsl.green ?? HSLBandPatch()).setting(\.luminance, value)
        case .hslAquaHue: hsl.aqua = (hsl.aqua ?? HSLBandPatch()).setting(\.hue, value)
        case .hslAquaSaturation: hsl.aqua = (hsl.aqua ?? HSLBandPatch()).setting(\.saturation, value)
        case .hslAquaLuminance: hsl.aqua = (hsl.aqua ?? HSLBandPatch()).setting(\.luminance, value)
        case .hslBlueHue: hsl.blue = (hsl.blue ?? HSLBandPatch()).setting(\.hue, value)
        case .hslBlueSaturation: hsl.blue = (hsl.blue ?? HSLBandPatch()).setting(\.saturation, value)
        case .hslBlueLuminance: hsl.blue = (hsl.blue ?? HSLBandPatch()).setting(\.luminance, value)
        case .hslPurpleHue: hsl.purple = (hsl.purple ?? HSLBandPatch()).setting(\.hue, value)
        case .hslPurpleSaturation: hsl.purple = (hsl.purple ?? HSLBandPatch()).setting(\.saturation, value)
        case .hslPurpleLuminance: hsl.purple = (hsl.purple ?? HSLBandPatch()).setting(\.luminance, value)
        case .hslMagentaHue: hsl.magenta = (hsl.magenta ?? HSLBandPatch()).setting(\.hue, value)
        case .hslMagentaSaturation: hsl.magenta = (hsl.magenta ?? HSLBandPatch()).setting(\.saturation, value)
        case .hslMagentaLuminance: hsl.magenta = (hsl.magenta ?? HSLBandPatch()).setting(\.luminance, value)
        case .splitToningShadowHue: splitToning.shadowHue = value
        case .splitToningShadowSaturation: splitToning.shadowSaturation = value
        case .splitToningHighlightHue: splitToning.highlightHue = value
        case .splitToningHighlightSaturation: splitToning.highlightSaturation = value
        case .splitToningBalance: splitToning.balance = value
        case .sharpeningAmount: sharpening.amount = value
        case .sharpeningRadius: sharpening.radius = value
        case .sharpeningDetail: sharpening.detail = value
        case .sharpeningMasking: sharpening.masking = value
        case .noiseReductionLuminanceAmount, .noiseReductionLuminanceDetail,
             .noiseReductionColorAmount, .noiseReductionColorDetail:
            break // never mapped in the registry -- spec §7: preserved only
        case .vignetteAmount: vignette.amount = value
        case .vignetteMidpoint: vignette.midpoint = value
        case .vignetteRoundness: vignette.roundness = value
        case .vignetteFeather: vignette.feather = value
        case .grainAmount: grain.amount = value
        case .grainSize: grain.size = value
        case .grainRoughness: grain.roughness = value
        }
    }

    func build() -> AdjustmentPatch {
        AdjustmentPatch(
            basic: basic,
            advancedToneCurve: advancedToneCurve,
            hsl: hsl,
            splitToning: splitToning,
            sharpening: sharpening,
            noiseReduction: nil,
            vignette: vignette,
            grain: grain
        )
    }
}

private extension HSLBandPatch {
    func setting(_ keyPath: WritableKeyPath<HSLBandPatch, Double?>, _ value: Double) -> HSLBandPatch {
        var copy = self
        copy[keyPath: keyPath] = value
        return copy
    }
}

/// Turns a `PresetDocument` back into an `.xmp` develop preset (spec §9.4).
public struct XMPExporter: Sendable {
    public struct Result: Equatable, Sendable {
        public var data: Data
        public var diagnostics: [XMPDiagnostic]
    }

    private let registry: XMPMappingRegistry
    private let codec: XMPCodec

    public init(registry: XMPMappingRegistry = .default, codec: XMPCodec = XMPCodec()) {
        self.registry = registry
        self.codec = codec
    }

    /// - Parameter context: a photo's white-balance baseline, if the caller
    ///   has one. Only meaningful for a `.native`-sourced preset's
    ///   temperature/tint, which are stored as LumaHarbor-relative offsets
    ///   with no fixed absolute value of their own (spec §7) -- an
    ///   `.adobeXMP`-sourced preset's temperature/tint are already absolute
    ///   and export regardless of `context`.
    public func export(_ preset: PresetDocument, context: PresetApplicationContext = .none) throws -> Result {
        var document = baseDocument(for: preset)
        var diagnostics: [XMPDiagnostic] = []

        for field in AdjustmentFieldID.allCases {
            guard field != .advancedToneCurve, field != .basicTemperature, field != .basicTint else { continue }
            guard let value = preset.patch.scalarValue(for: field) else { continue }
            export(field: field, value: value, into: &document, diagnostics: &diagnostics)
        }

        exportWhiteBalance(preset: preset, context: context, into: &document, diagnostics: &diagnostics)

        if let curve = preset.patch.advancedToneCurve {
            document.properties[.cameraRaw("ToneCurvePV2012")] = XMPImporter.exportToneCurve(curve)
        }

        let data = try codec.serialize(document)
        return Result(data: data, diagnostics: diagnostics)
    }

    /// Starts from the original packet's own property graph when this
    /// preset came from one, so unmapped/unknown properties round-trip
    /// (spec §9.4: "從 XMP 匯入的 Preset 匯出時保留 unknown／preserved property").
    private func baseDocument(for preset: PresetDocument) -> XMPDocument {
        if let envelope = preset.xmpEnvelope,
           let originalData = envelope.originalPacketUTF8.data(using: .utf8),
           let parsed = try? codec.parse(originalData) {
            return parsed
        }
        return XMPDocument(about: "")
    }

    private func export(
        field: AdjustmentFieldID,
        value: Double,
        into document: inout XMPDocument,
        diagnostics: inout [XMPDiagnostic]
    ) {
        guard let mapping = registry.mapping(for: field) else {
            diagnostics.append(XMPDiagnostic(severity: .warning, code: "reverseMappingUnavailable", detail: field.rawValue))
            return
        }
        guard let exportScalar = mapping.exportScalar else {
            diagnostics.append(XMPDiagnostic(severity: .warning, code: "reverseMappingUnavailable", propertyID: mapping.propertyID))
            return
        }
        do {
            document.properties[mapping.propertyID] = try exportScalar(value)
        } catch {
            diagnostics.append(XMPDiagnostic(severity: .warning, code: "reverseMappingFailed", propertyID: mapping.propertyID))
        }
    }

    private func exportWhiteBalance(
        preset: PresetDocument,
        context: PresetApplicationContext,
        into document: inout XMPDocument,
        diagnostics: inout [XMPDiagnostic]
    ) {
        guard let basic = preset.patch.basic, basic.temperature != nil || basic.tint != nil else { return }

        var wroteAny = false
        if let temperature = basic.temperature {
            if let absolute = absoluteWhiteBalanceValue(
                relativeOrAbsolute: temperature, source: preset.source,
                baseline: context.baselineTemperatureKelvin, span: AdjustmentMapping.kelvinPerTemperatureUnit
            ) {
                document.properties[.cameraRaw("Temperature")] = .text(XMPMappingRegistry.format(absolute))
                wroteAny = true
            } else {
                diagnostics.append(XMPDiagnostic(
                    severity: .warning, code: "reverseMappingUnavailable", propertyID: .cameraRaw("Temperature"),
                    detail: "no baseline photo to convert a relative offset into an absolute value"
                ))
            }
        }
        if let tint = basic.tint {
            if let absolute = absoluteWhiteBalanceValue(
                relativeOrAbsolute: tint, source: preset.source,
                baseline: context.baselineTint, span: AdjustmentMapping.tintPerUnit
            ) {
                document.properties[.cameraRaw("Tint")] = .text(XMPMappingRegistry.format(absolute))
                wroteAny = true
            } else {
                diagnostics.append(XMPDiagnostic(
                    severity: .warning, code: "reverseMappingUnavailable", propertyID: .cameraRaw("Tint"),
                    detail: "no baseline photo to convert a relative offset into an absolute value"
                ))
            }
        }
        if wroteAny {
            document.properties[.cameraRaw("WhiteBalance")] = .text("Custom")
        }
    }

    private func absoluteWhiteBalanceValue(
        relativeOrAbsolute value: Double,
        source: PresetSource,
        baseline: Double?,
        span: Double
    ) -> Double? {
        switch source {
        case .adobeXMP:
            // Already absolute -- this is exactly what was imported (or, if
            // the user edited it, still the same absolute-Kelvin space it
            // was imported in; Phase 1 has no per-field-provenance UI that
            // could turn it into a relative offset).
            return value
        case .native:
            guard let baseline else { return nil }
            return baseline + value * span
        }
    }
}
