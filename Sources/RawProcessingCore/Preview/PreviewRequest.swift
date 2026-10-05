import CoreGraphics
import Foundation

/// Which photo a preview belongs to.
///
/// A plain UUID wrapper rather than `PhotoID` so `RawProcessingCore` stays
/// independent of the library layer.
public struct PreviewSubject: Hashable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public enum PreviewQuality: Int, Comparable, Sendable, CaseIterable {
    /// Draft decode, issued while the user is still dragging.
    case interactive = 0
    /// Full-precision decode, issued once input settles.
    case high = 1
    /// Native-resolution decode for parity checks and clients that need the
    /// exact export recipe without writing an output file.
    case full = 2

    public static func < (lhs: PreviewQuality, rhs: PreviewQuality) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Identifies exactly one preview attempt.
///
/// The generation counter is what makes stale results detectable: it is issued
/// by the scheduler, monotonically increasing across every subject, and travels
/// with the result all the way to the view model.
public struct PreviewToken: Hashable, Sendable {
    public let subject: PreviewSubject
    public let generation: UInt64
    /// Session context captured at submission so late actor-hop results can
    /// be rejected even when the scheduler generation is still monotonic.
    public let contextID: UUID?

    public init(subject: PreviewSubject, generation: UInt64, contextID: UUID? = nil) {
        self.subject = subject
        self.generation = generation
        self.contextID = contextID
    }
}

public struct PreviewRequest: Sendable {
    public var subject: PreviewSubject
    public var url: URL
    public var adjustments: PhotoAdjustments
    /// Longest edge, in pixels, the preview should cover.
    public var targetPixelDimension: Int
    public var quality: PreviewQuality
    public var previewOptions: ProfessionalPreviewOptions
    public var cameraProfileRequest: RawCameraProfileRequest?
    public var contextID: UUID?

    public init(
        subject: PreviewSubject,
        url: URL,
        adjustments: PhotoAdjustments,
        targetPixelDimension: Int,
        quality: PreviewQuality,
        previewOptions: ProfessionalPreviewOptions = .standard,
        cameraProfileRequest: RawCameraProfileRequest? = nil,
        contextID: UUID? = nil
    ) {
        self.subject = subject
        self.url = url
        self.adjustments = adjustments
        self.targetPixelDimension = targetPixelDimension
        self.quality = quality
        self.previewOptions = previewOptions
        self.cameraProfileRequest = cameraProfileRequest
        self.contextID = contextID
    }

    public var decodeQuality: DecodeQuality {
        switch quality {
        case .interactive:
            return .interactive(maximumPixelDimension: targetPixelDimension)
        case .high:
            return .highQuality(maximumPixelDimension: targetPixelDimension)
        case .full:
            return .full
        }
    }
}

/// A rendered preview bitmap.
public struct PreviewImage: @unchecked Sendable {
    public let cgImage: CGImage
    public let pixelSize: CGSize
    /// The decoded photo's as-shot neutral, when the renderer's decoder
    /// reports one. `nil` for callers (tests, fakes) that don't need it —
    /// keeping this optional with a default is what lets every existing
    /// `PreviewImage(cgImage:pixelSize:)` call site stay source-compatible.
    public let whiteBalanceBaseline: RawWhiteBalanceBaseline?
    public let rawRenderRecipe: ResolvedRawRenderRecipe?

    public init(
        cgImage: CGImage,
        pixelSize: CGSize,
        whiteBalanceBaseline: RawWhiteBalanceBaseline? = nil,
        rawRenderRecipe: ResolvedRawRenderRecipe? = nil
    ) {
        self.cgImage = cgImage
        self.pixelSize = pixelSize
        self.whiteBalanceBaseline = whiteBalanceBaseline
        self.rawRenderRecipe = rawRenderRecipe
    }
}

public struct PreviewResult: @unchecked Sendable {
    public let token: PreviewToken
    public let quality: PreviewQuality
    public let image: PreviewImage

    public init(token: PreviewToken, quality: PreviewQuality, image: PreviewImage) {
        self.token = token
        self.quality = quality
        self.image = image
    }
}

public enum PreviewEvent: @unchecked Sendable {
    case produced(PreviewResult)
    case failed(PreviewToken, Error)
}

/// The renderer seam.
///
/// Injecting this is what lets the cancellation and staleness rules be tested
/// deterministically with a fake that never touches a GPU or a RAW file.
public protocol PreviewRendering: Sendable {
    func render(_ request: PreviewRequest) async throws -> PreviewImage
}
