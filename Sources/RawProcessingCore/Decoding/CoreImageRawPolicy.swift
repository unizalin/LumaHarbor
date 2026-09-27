import CoreImage
import Foundation
import ImageIO

/// The versioned Core Image option vector used by the Adobe compatibility
/// path. A `nil` field preserves the decoder's per-RAW default. Gate 2 must
/// provide evidence before this vector may override a tone/detail property.
public struct CoreImageRawOptionVector: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let exposure: Float?
    public let baselineExposure: Float?
    public let shadowBias: Float?
    public let boostAmount: Float?
    public let boostShadowAmount: Float?
    public let gamutMappingEnabled: Bool?
    public let luminanceNoiseReductionAmount: Float?
    public let colorNoiseReductionAmount: Float?
    public let sharpnessAmount: Float?
    public let contrastAmount: Float?
    public let detailAmount: Float?
    public let moireReductionAmount: Float?
    public let localToneMapAmount: Float?
    public let extendedDynamicRangeAmount: Float?
    public let highlightRecoveryEnabled: Bool?

    public static let adobeProcess2012V1 = Self(
        id: "adobe-process-2012-v1-preserve-defaults-v1"
    )

    public init(
        id: String,
        exposure: Float? = nil,
        baselineExposure: Float? = nil,
        shadowBias: Float? = nil,
        boostAmount: Float? = nil,
        boostShadowAmount: Float? = nil,
        gamutMappingEnabled: Bool? = nil,
        luminanceNoiseReductionAmount: Float? = nil,
        colorNoiseReductionAmount: Float? = nil,
        sharpnessAmount: Float? = nil,
        contrastAmount: Float? = nil,
        detailAmount: Float? = nil,
        moireReductionAmount: Float? = nil,
        localToneMapAmount: Float? = nil,
        extendedDynamicRangeAmount: Float? = nil,
        highlightRecoveryEnabled: Bool? = nil
    ) {
        self.id = id
        self.exposure = exposure
        self.baselineExposure = baselineExposure
        self.shadowBias = shadowBias
        self.boostAmount = boostAmount
        self.boostShadowAmount = boostShadowAmount
        self.gamutMappingEnabled = gamutMappingEnabled
        self.luminanceNoiseReductionAmount = luminanceNoiseReductionAmount
        self.colorNoiseReductionAmount = colorNoiseReductionAmount
        self.sharpnessAmount = sharpnessAmount
        self.contrastAmount = contrastAmount
        self.detailAmount = detailAmount
        self.moireReductionAmount = moireReductionAmount
        self.localToneMapAmount = localToneMapAmount
        self.extendedDynamicRangeAmount = extendedDynamicRangeAmount
        self.highlightRecoveryEnabled = highlightRecoveryEnabled
    }
}

public struct CoreImageRawPolicyResolution: Codable, Equatable, Hashable, Sendable {
    public let optionVector: CoreImageRawOptionVector
    public let decoderVersion: String?
    public let diagnostics: [RawRenderDiagnosticCode]

    public init(
        optionVector: CoreImageRawOptionVector,
        decoderVersion: String?,
        diagnostics: [RawRenderDiagnosticCode] = []
    ) {
        self.optionVector = optionVector
        self.decoderVersion = decoderVersion
        self.diagnostics = diagnostics
    }
}

/// Pure policy decisions shared by the Core Image decoder and its tests.
public enum CoreImageRawPolicy {
    /// The same preference order is used on macOS and iPadOS. Core Image's
    /// supported list is sorted by the OS, so we never choose the newest
    /// version opportunistically when the compatibility contract asks for a
    /// known version.
    public static let preferredDecoderVersions = ["9", "8", "7", "6"]

    public static func optionVector(for policy: RawRenderingCompatibility) -> CoreImageRawOptionVector? {
        guard policy == .adobeProcess2012V1 else { return nil }
        return .adobeProcess2012V1
    }

    public static func resolveAdobeProcess2012V1(
        supportedDecoderVersions: [String]
    ) -> CoreImageRawPolicyResolution {
        let selected = preferredDecoderVersions.first { supportedDecoderVersions.contains($0) }
        return CoreImageRawPolicyResolution(
            optionVector: .adobeProcess2012V1,
            decoderVersion: selected,
            diagnostics: selected == nil ? [.rawDecoderVersionFallback] : []
        )
    }

    public static func orientation(for rawValue: Int?) -> CGImagePropertyOrientation {
        guard let rawValue, (1...8).contains(rawValue),
              let orientation = CGImagePropertyOrientation(rawValue: UInt32(rawValue)) else {
            return .up
        }
        return orientation
    }
}
