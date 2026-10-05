import CoreImage
import Localization
import Foundation
import ImageIO

/// The MVP decoder: Apple's `CIRAWFilter`.
///
/// It is the only type in the project allowed to construct a `CIRAWFilter`
/// (spec §5.1). White balance is applied here rather than in the adjustment
/// chain because for a RAW file the neutral point belongs to demosaicing — a
/// `CITemperatureAndTint` after the fact would fight the decoder's own
/// rendering.
public struct CoreImageRawDecoder: RawDecoding {
    public let identifier = DecoderIdentifier(kind: "coreImage", version: "system-default")

    public init() {}

    public func supportsFile(at url: URL) -> Bool {
        // `CIRAWFilter(imageURL:)` itself is lazy: it returns non-nil for a
        // missing file or for garbage bytes alike, deferring any real
        // validation to `nativeSize`/`outputImage`. `nativeSize` is the same
        // signal `decode(_:)` already uses to detect a corrupted file, so it
        // is what actually answers "is this a supported RAW".
        guard let filter = CIRAWFilter(imageURL: url) else { return false }
        let size = filter.nativeSize
        return size.width > 0 && size.height > 0
    }

    public func readMetadata(at url: URL) throws -> RawMetadata {
        let source = try makeImageSource(for: url)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any] else {
            throw RawDecodingError.corruptedFile(path: url.path)
        }
        return RawMetadata.from(imageProperties: properties)
    }

    public func decode(_ request: RawDecodeRequest) throws -> DecodedRawImage {
        let url = request.url

        // Establish *why* a decode would fail before asking CIRAWFilter, which
        // returns a bare nil for "missing", "damaged" and "unsupported" alike.
        let source = try makeImageSource(for: url)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]

        guard let filter = CIRAWFilter(imageURL: url) else {
            throw RawDecodingError.unsupportedFormat(path: url.path)
        }

        let nativeSize = filter.nativeSize
        guard nativeSize.width > 0, nativeSize.height > 0 else {
            throw RawDecodingError.corruptedFile(path: url.path)
        }

        var metadata = properties.map(RawMetadata.from(imageProperties:)) ?? RawMetadata()
        var recipe = request.rawRenderRecipe
        // Read the as-shot neutral before overwriting it, so the sidecar's
        // offsets stay relative to what the camera recorded.
        let baselineTemperature = Double(filter.neutralTemperature)
        let baselineTint = Double(filter.neutralTint)

        if let existingRecipe = recipe, let profileRequest = request.cameraProfileRequest {
            recipe = RawRenderRecipeResolver().resolvingCameraProfile(
                in: existingRecipe,
                request: profileRequest,
                cameraMake: metadata.cameraMake,
                cameraModel: metadata.cameraModel
            )
        }

        // Set orientation explicitly from source metadata. This keeps the
        // decoder contract stable instead of relying on a system default.
        filter.orientation = CoreImageRawPolicy.orientation(for: metadata.orientation)

        // `rawRenderingCompatibility` is persisted user intent. Only the
        // resolved recipe can authorize the uncalibrated Adobe option vector;
        // a missing recipe is therefore native by default (fail closed).
        if recipe?.effectivePolicy == .adobeProcess2012V1 {
            let resolution = CoreImageRawPolicy.resolveAdobeProcess2012V1(
                supportedDecoderVersions: filter.supportedDecoderVersions.map(\.rawValue)
            )
            if let decoderVersion = resolution.decoderVersion {
                filter.decoderVersion = CIRAWDecoderVersion(rawValue: decoderVersion)
            }
            Self.apply(resolution.optionVector, to: filter)

            var diagnostics = resolution.diagnostics.map {
                RawRenderDiagnostic(code: $0)
            }
            diagnostics.append(contentsOf: Self.unsupportedOptionDiagnostics(
                for: filter,
                vector: resolution.optionVector
            ))
            recipe = recipe?.addingDiagnostics(diagnostics)
        }

        if !request.whiteBalance.isAsShot {
            guard let resolvedWhiteBalance = Self.resolvedWhiteBalance(
                for: request.whiteBalance,
                baselineTemperature: baselineTemperature,
                baselineTint: baselineTint
            ) else {
                throw RawDecodingError.decodeFailed(
                    path: url.path,
                    reason: L10n.t("The white-balance baseline is unavailable or invalid.")
                )
            }
            // Assign only the safe, baseline-relative values. This is the
            // final UI-independent defence for callers that construct a raw
            // request directly and bypass the presentation/input layer.
            filter.neutralTemperature = Float(baselineTemperature + resolvedWhiteBalance.temperatureOffsetKelvin)
            filter.neutralTint = Float(baselineTint + resolvedWhiteBalance.tintOffset)
        }

        let scaleFactor = Self.scaleFactor(
            nativeSize: nativeSize,
            maximumPixelDimension: request.quality.maximumPixelDimension
        )
        filter.scaleFactor = Float(scaleFactor)
        filter.isDraftModeEnabled = request.quality.allowsDraftMode

        // Automatic lens correction only, and only when the vendor actually
        // supports it (design spec §6.4 item 2) -- .off/.manual/.bundledProfile
        // explicitly disable it so the decoder's own correction never doubles
        // up with the post-decode manual/profile pass in AdjustmentPipeline
        // (§6.4: "不得同時套用").
        if request.lensCorrection.decoderShouldEnableLensCorrection {
            if filter.isLensCorrectionSupported {
                filter.isLensCorrectionEnabled = true
            }
        } else {
            filter.isLensCorrectionEnabled = false
        }

        guard let output = filter.outputImage else {
            throw RawDecodingError.decodeFailed(
                path: url.path,
                reason: L10n.t("The system RAW decoder returned no image.")
            )
        }

        let metadataNeededFallback = properties == nil
            || metadata.pixelWidth == 0
            || metadata.pixelHeight == 0
        if metadata.pixelWidth == 0 || metadata.pixelHeight == 0 {
            metadata.pixelWidth = Int(nativeSize.width.rounded())
            metadata.pixelHeight = Int(nativeSize.height.rounded())
        }
        if metadataNeededFallback {
            recipe = recipe?.addingDiagnostics([
                RawRenderDiagnostic(code: .metadataFallback)
            ])
        }

        return DecodedRawImage(
            image: output,
            nativePixelSize: nativeSize,
            decodedPixelSize: output.extent.size,
            baselineTemperature: baselineTemperature,
            baselineTint: baselineTint,
            metadata: metadata,
            rawRenderRecipe: recipe
        )
    }

    /// Final, UI-independent white-balance validation shared by preview and
    /// export. Keeping this pure makes the native filter assignment testable
    /// without requiring a private RAW fixture.
    public static func resolvedWhiteBalance(
        for request: RawWhiteBalance,
        baselineTemperature: Double,
        baselineTint: Double
    ) -> RawWhiteBalance? {
        guard !request.isAsShot else { return .asShot }
        guard baselineTint.isFinite,
              request.tintOffset.isFinite,
              let safeOffsetKelvin = WhiteBalancePresentation.resolve(
                  offsetKelvin: request.temperatureOffsetKelvin,
                  baselineKelvin: baselineTemperature
              ) else {
            return nil
        }
        let safeTint = min(max(request.tintOffset, -150), 150)
        return RawWhiteBalance(
            temperatureOffsetKelvin: safeOffsetKelvin,
            tintOffset: safeTint
        )
    }

    // MARK: - Helpers

    /// Longest-edge fit, never upscaling. `nil` (export) keeps native size.
    static func scaleFactor(nativeSize: CGSize, maximumPixelDimension: Int?) -> Double {
        guard let maximum = maximumPixelDimension, maximum > 0 else { return 1 }
        let longestEdge = Double(max(nativeSize.width, nativeSize.height))
        guard longestEdge > 0 else { return 1 }
        return min(1, Double(maximum) / longestEdge)
    }

    private static func apply(_ vector: CoreImageRawOptionVector, to filter: CIRAWFilter) {
        if let value = vector.exposure { filter.exposure = value }
        if let value = vector.baselineExposure { filter.baselineExposure = value }
        if let value = vector.shadowBias { filter.shadowBias = value }
        if let value = vector.boostAmount { filter.boostAmount = value }
        if let value = vector.boostShadowAmount { filter.boostShadowAmount = value }
        if let value = vector.gamutMappingEnabled { filter.isGamutMappingEnabled = value }
        if filter.isLuminanceNoiseReductionSupported,
           let value = vector.luminanceNoiseReductionAmount {
            filter.luminanceNoiseReductionAmount = value
        }
        if filter.isColorNoiseReductionSupported,
           let value = vector.colorNoiseReductionAmount {
            filter.colorNoiseReductionAmount = value
        }
        if filter.isSharpnessSupported, let value = vector.sharpnessAmount {
            filter.sharpnessAmount = value
        }
        if filter.isContrastSupported, let value = vector.contrastAmount {
            filter.contrastAmount = value
        }
        if filter.isDetailSupported, let value = vector.detailAmount {
            filter.detailAmount = value
        }
        if filter.isMoireReductionSupported, let value = vector.moireReductionAmount {
            filter.moireReductionAmount = value
        }
        if filter.isLocalToneMapSupported, let value = vector.localToneMapAmount {
            filter.localToneMapAmount = value
        }
        if let value = vector.extendedDynamicRangeAmount {
            filter.extendedDynamicRangeAmount = value
        }
        if #available(macOS 26.0, iOS 19.0, *),
           filter.isHighlightRecoverySupported,
           let enabled = vector.highlightRecoveryEnabled {
            filter.isHighlightRecoveryEnabled = enabled
        }
    }

    private static func unsupportedOptionDiagnostics(
        for filter: CIRAWFilter,
        vector: CoreImageRawOptionVector
    ) -> [RawRenderDiagnostic] {
        var diagnostics: [RawRenderDiagnostic] = []
        let highlightRecoverySupported: Bool
        if #available(macOS 26.0, iOS 19.0, *) {
            highlightRecoverySupported = filter.isHighlightRecoverySupported
        } else {
            highlightRecoverySupported = false
        }
        let support: [(String, Bool, Bool)] = [
            ("highlightRecovery", vector.highlightRecoveryEnabled != nil, highlightRecoverySupported),
            ("luminanceNoiseReduction", vector.luminanceNoiseReductionAmount != nil, filter.isLuminanceNoiseReductionSupported),
            ("colorNoiseReduction", vector.colorNoiseReductionAmount != nil, filter.isColorNoiseReductionSupported),
            ("sharpness", vector.sharpnessAmount != nil, filter.isSharpnessSupported),
            ("contrast", vector.contrastAmount != nil, filter.isContrastSupported),
            ("detail", vector.detailAmount != nil, filter.isDetailSupported),
            ("moireReduction", vector.moireReductionAmount != nil, filter.isMoireReductionSupported),
            ("localToneMap", vector.localToneMapAmount != nil, filter.isLocalToneMapSupported)
        ]
        for (name, isRequested, isSupported) in support where isRequested && !isSupported {
            diagnostics.append(RawRenderDiagnostic(code: .rawOptionUnavailable, detail: name))
        }
        return diagnostics
    }

    private func makeImageSource(for url: URL) throws -> CGImageSource {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RawDecodingError.fileUnavailable(path: url.path)
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw RawDecodingError.fileUnavailable(path: url.path)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw RawDecodingError.corruptedFile(path: url.path)
        }
        return source
    }
}

extension CoreImageRawDecoder {
    /// File extensions the scanner treats as candidate RAWs.
    ///
    /// This is a fast pre-filter only — `supportsFile(at:)` still decides. Sony
    /// `.ARW` is the MVP's required format; the rest are here because
    /// `CIRAWFilter` handles them and excluding them would be arbitrary.
    public static let candidateFileExtensions: Set<String> = [
        "arw", "sr2", "srf",           // Sony
        "cr2", "cr3", "crw",           // Canon
        "nef", "nrw",                  // Nikon
        "raf",                         // Fujifilm
        "orf",                         // Olympus / OM System
        "rw2",                         // Panasonic
        "pef",                         // Pentax
        "dng",                         // Adobe / Apple ProRAW
        "erf", "3fr", "fff", "iiq",    // Epson, Hasselblad, Phase One
        "gpr"                          // GoPro
    ]
}
