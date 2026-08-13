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

    public init(subject: PreviewSubject, generation: UInt64) {
        self.subject = subject
        self.generation = generation
    }
}

public struct PreviewRequest: Sendable {
    public var subject: PreviewSubject
    public var url: URL
    public var adjustments: PhotoAdjustments
    /// Longest edge, in pixels, the preview should cover.
    public var targetPixelDimension: Int
    public var quality: PreviewQuality

    public init(
        subject: PreviewSubject,
        url: URL,
        adjustments: PhotoAdjustments,
        targetPixelDimension: Int,
        quality: PreviewQuality
    ) {
        self.subject = subject
        self.url = url
        self.adjustments = adjustments
        self.targetPixelDimension = targetPixelDimension
        self.quality = quality
    }

    public var decodeQuality: DecodeQuality {
        switch quality {
        case .interactive:
            return .interactive(maximumPixelDimension: targetPixelDimension)
        case .high:
            return .highQuality(maximumPixelDimension: targetPixelDimension)
        }
    }
}

/// A rendered preview bitmap.
public struct PreviewImage: @unchecked Sendable {
    public let cgImage: CGImage
    public let pixelSize: CGSize

    public init(cgImage: CGImage, pixelSize: CGSize) {
        self.cgImage = cgImage
        self.pixelSize = pixelSize
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
