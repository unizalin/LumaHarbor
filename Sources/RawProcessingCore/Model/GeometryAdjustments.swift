import Foundation

/// Non-destructive crop/rotate/flip/straighten/perspective state for one photo
/// (design spec §6.5, roadmap Phase 2 "Data model").
///
/// Phase 2 Task 1 is model + sidecar compatibility only: nothing here reads a
/// decoded image, builds a `CGAffineTransform`, or feeds `RenderPipeline` /
/// `AdjustmentMapping`. That wiring is Task 2.2's job, so `AdjustmentMapping
/// .renderParameters(for:)` deliberately does not look at this struct yet —
/// `AdjustmentMappingTests.testGeometryNeverAffectsRenderParameters` pins that.
public struct GeometryAdjustments: Codable, Equatable, Hashable, Sendable {
    /// `nil` means "no crop" — the full source frame. `NormalizedCropRect`
    /// itself always self-validates, so an out-of-range rect can't exist here.
    public var crop: NormalizedCropRect?
    public var cropAspectRatio: CropAspectRatio

    /// Always one of 0/90/180/270 — "rotate 90°" is a discrete action (spec
    /// §6.5), not a free slider, so any other value is snapped to the nearest
    /// quarter turn and wrapped into `[0, 360)`.
    public var rotationDegrees: Double {
        didSet { rotationDegrees = Self.normalizedQuarterTurn(rotationDegrees) }
    }
    public var flipHorizontal: Bool
    public var flipVertical: Bool

    /// The fine-angle straighten slider, independent of the 90° rotate action.
    public var straightenDegrees: Double {
        didSet { straightenDegrees = Self.clamp(straightenDegrees, to: Self.straightenRange) }
    }

    /// Placeholder inputs for Task 2.2's perspective correction (spec §6.5:
    /// "廣角變形...至少水平與垂直方向"). Percentage-style span, matching the
    /// other ±100 adjustment sliders (`AdjustmentMapping`'s contrast/
    /// saturation/vibrance spans) rather than degrees, since the exact
    /// projective-transform units are a Task 2.2 render decision.
    public var perspectiveHorizontal: Double {
        didSet { perspectiveHorizontal = Self.clamp(perspectiveHorizontal, to: Self.perspectiveRange) }
    }
    public var perspectiveVertical: Double {
        didSet { perspectiveVertical = Self.clamp(perspectiveVertical, to: Self.perspectiveRange) }
    }

    /// P5: 4-corner perspective correction pins in normalized [0, 1] coordinates.
    public var cornerPins: PerspectiveCornerPins?

    public static let straightenRange: ClosedRange<Double> = -45...45
    public static let perspectiveRange: ClosedRange<Double> = -100...100

    public init(
        crop: NormalizedCropRect? = nil,
        cropAspectRatio: CropAspectRatio = .freeform,
        rotationDegrees: Double = 0,
        flipHorizontal: Bool = false,
        flipVertical: Bool = false,
        straightenDegrees: Double = 0,
        perspectiveHorizontal: Double = 0,
        perspectiveVertical: Double = 0,
        cornerPins: PerspectiveCornerPins? = nil
    ) {
        self.crop = crop
        self.cropAspectRatio = cropAspectRatio
        self.rotationDegrees = Self.normalizedQuarterTurn(rotationDegrees)
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
        self.straightenDegrees = Self.clamp(straightenDegrees, to: Self.straightenRange)
        self.perspectiveHorizontal = Self.clamp(perspectiveHorizontal, to: Self.perspectiveRange)
        self.perspectiveVertical = Self.clamp(perspectiveVertical, to: Self.perspectiveRange)
        self.cornerPins = cornerPins
    }

    /// No crop, no rotation, no flip, no straighten, no perspective — the
    /// "this photo renders exactly like it always has" state. A sidecar
    /// written before this field existed decodes to exactly this value.
    public static let neutral = GeometryAdjustments()

    public var isIdentity: Bool {
        crop == nil &&
        rotationDegrees == 0 &&
        !flipHorizontal &&
        !flipVertical &&
        straightenDegrees == 0 &&
        perspectiveHorizontal == 0 &&
        perspectiveVertical == 0 &&
        (cornerPins == nil || cornerPins?.isIdentity == true)
    }

    // MARK: - Discrete actions

    public func rotatedClockwise() -> GeometryAdjustments {
        var copy = self
        copy.rotationDegrees += 90
        return copy
    }

    public func rotatedCounterclockwise() -> GeometryAdjustments {
        var copy = self
        copy.rotationDegrees -= 90
        return copy
    }

    public func flippingHorizontal() -> GeometryAdjustments {
        var copy = self
        copy.flipHorizontal.toggle()
        return copy
    }

    public func flippingVertical() -> GeometryAdjustments {
        var copy = self
        copy.flipVertical.toggle()
        return copy
    }

    /// Clears the crop and returns its aspect-ratio lock to freeform, leaving
    /// rotation/flip/straighten/perspective untouched.
    public func resettingCrop() -> GeometryAdjustments {
        var copy = self
        copy.crop = nil
        copy.cropAspectRatio = .freeform
        return copy
    }

    public func resettingRotation() -> GeometryAdjustments {
        var copy = self
        copy.rotationDegrees = 0
        return copy
    }

    public func resettingStraighten() -> GeometryAdjustments {
        var copy = self
        copy.straightenDegrees = 0
        return copy
    }

    public func resettingPerspective() -> GeometryAdjustments {
        var copy = self
        copy.perspectiveHorizontal = 0
        copy.perspectiveVertical = 0
        copy.cornerPins = nil
        return copy
    }

    /// Every field back to neutral in one step (the panel's "Reset" button).
    public func reset() -> GeometryAdjustments { .neutral }

    // MARK: - Validation

    private static func normalizedQuarterTurn(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        let snapped = (value / 90).rounded() * 90
        let wrapped = snapped.truncatingRemainder(dividingBy: 360)
        return wrapped < 0 ? wrapped + 360 : wrapped
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return 0 }
        return Swift.min(Swift.max(value, range.lowerBound), range.upperBound)
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case crop, cropAspectRatio, rotationDegrees, flipHorizontal, flipVertical
        case straightenDegrees, perspectiveHorizontal, perspectiveVertical
        case cornerPins
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            crop: try container.decodeIfPresent(NormalizedCropRect.self, forKey: .crop),
            cropAspectRatio: try container.decodeIfPresent(CropAspectRatio.self, forKey: .cropAspectRatio) ?? .freeform,
            rotationDegrees: try container.decodeIfPresent(Double.self, forKey: .rotationDegrees) ?? 0,
            flipHorizontal: try container.decodeIfPresent(Bool.self, forKey: .flipHorizontal) ?? false,
            flipVertical: try container.decodeIfPresent(Bool.self, forKey: .flipVertical) ?? false,
            straightenDegrees: try container.decodeIfPresent(Double.self, forKey: .straightenDegrees) ?? 0,
            perspectiveHorizontal: try container.decodeIfPresent(Double.self, forKey: .perspectiveHorizontal) ?? 0,
            perspectiveVertical: try container.decodeIfPresent(Double.self, forKey: .perspectiveVertical) ?? 0,
            cornerPins: try container.decodeIfPresent(PerspectiveCornerPins.self, forKey: .cornerPins)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(crop, forKey: .crop)
        try container.encode(cropAspectRatio, forKey: .cropAspectRatio)
        try container.encode(rotationDegrees, forKey: .rotationDegrees)
        try container.encode(flipHorizontal, forKey: .flipHorizontal)
        try container.encode(flipVertical, forKey: .flipVertical)
        try container.encode(straightenDegrees, forKey: .straightenDegrees)
        try container.encode(perspectiveHorizontal, forKey: .perspectiveHorizontal)
        try container.encode(perspectiveVertical, forKey: .perspectiveVertical)
        try container.encodeIfPresent(cornerPins, forKey: .cornerPins)
    }
}

public struct NormalizedPoint: Codable, Equatable, Hashable, Sendable {
    public var x: Double { didSet { x = Swift.min(Swift.max(x.isFinite ? x : 0, 0), 1) } }
    public var y: Double { didSet { y = Swift.min(Swift.max(y.isFinite ? y : 0, 0), 1) } }

    public init(x: Double, y: Double) {
        self.x = Swift.min(Swift.max(x.isFinite ? x : 0, 0), 1)
        self.y = Swift.min(Swift.max(y.isFinite ? y : 0, 0), 1)
    }
}

public struct PerspectiveCornerPins: Codable, Equatable, Hashable, Sendable {
    public var topLeft: NormalizedPoint
    public var topRight: NormalizedPoint
    public var bottomLeft: NormalizedPoint
    public var bottomRight: NormalizedPoint

    public init(
        topLeft: NormalizedPoint = NormalizedPoint(x: 0, y: 0),
        topRight: NormalizedPoint = NormalizedPoint(x: 1, y: 0),
        bottomLeft: NormalizedPoint = NormalizedPoint(x: 0, y: 1),
        bottomRight: NormalizedPoint = NormalizedPoint(x: 1, y: 1)
    ) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomLeft = bottomLeft
        self.bottomRight = bottomRight
    }

    public static let standard = PerspectiveCornerPins()

    public var isIdentity: Bool {
        topLeft == NormalizedPoint(x: 0, y: 0) &&
        topRight == NormalizedPoint(x: 1, y: 0) &&
        bottomLeft == NormalizedPoint(x: 0, y: 1) &&
        bottomRight == NormalizedPoint(x: 1, y: 1)
    }
}

/// A crop rectangle in normalized `[0, 1]` source-image coordinates, origin
/// at the top-left, independent of pixel size so it survives re-decodes at a
/// different resolution (thumbnail vs. preview vs. full export).
///
/// Every initializer clamps rather than rejects: a hand-edited or
/// future-version sidecar degrades to a valid rect instead of failing to
/// open, matching `PhotoAdjustments`'s own out-of-range convention.
public struct NormalizedCropRect: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    /// Below this, a crop is indistinguishable from a zero-area selection
    /// (and would divide-by-zero downstream in aspect-ratio math), so width
    /// and height are floored here rather than allowed to reach 0.
    public static let minimumDimension = 0.01

    public init(x: Double, y: Double, width: Double, height: Double) {
        (self.x, self.y, self.width, self.height) = Self.clamped(x: x, y: y, width: width, height: height)
    }

    /// The entire source frame — the "no crop" rectangle. `GeometryAdjustments
    /// .crop` uses `nil` rather than this to mean "no crop", so this exists
    /// for callers that need a concrete rect (e.g. an aspect-ratio-lock UI
    /// initializing its overlay), not as the sidecar's neutral encoding.
    public static let full = NormalizedCropRect(x: 0, y: 0, width: 1, height: 1)

    public var isFull: Bool { self == .full }

    public var aspectRatio: Double { width / height }

    private static func clamped(x: Double, y: Double, width: Double, height: Double) -> (Double, Double, Double, Double) {
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite else {
            return (0, 0, 1, 1)
        }
        let clampedWidth = Swift.min(Swift.max(width, minimumDimension), 1)
        let clampedHeight = Swift.min(Swift.max(height, minimumDimension), 1)
        // Keep the requested size and slide the origin back into frame,
        // rather than shrinking the size, when x/width (or y/height) would
        // otherwise run past the edge.
        let clampedX = Swift.min(Swift.max(x, 0), 1 - clampedWidth)
        let clampedY = Swift.min(Swift.max(y, 0), 1 - clampedHeight)
        return (clampedX, clampedY, clampedWidth, clampedHeight)
    }

    private enum CodingKeys: String, CodingKey { case x, y, width, height }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            x: try container.decodeIfPresent(Double.self, forKey: .x) ?? 0,
            y: try container.decodeIfPresent(Double.self, forKey: .y) ?? 0,
            width: try container.decodeIfPresent(Double.self, forKey: .width) ?? 1,
            height: try container.decodeIfPresent(Double.self, forKey: .height) ?? 1
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
    }
}

/// The crop tool's aspect-ratio lock. Kept separate from `NormalizedCropRect`
/// itself: the ratio is a tool *setting* (persists across a crop being
/// cleared and redrawn), not a property of any one rectangle.
public enum CropAspectRatio: Codable, Equatable, Hashable, Sendable {
    /// No lock — the crop handles move independently.
    case freeform
    /// Locked to the source image's own decoded pixel aspect. This type has
    /// no decoded pixel size to compute that from, so `fixedRatio` is `nil`
    /// here too; the UI layer resolves it against the actual decode.
    case original
    case square
    case custom(width: Double, height: Double)

    /// The numeric width/height ratio this case pins the crop to, or `nil`
    /// when the ratio depends on something this pure model doesn't have
    /// (`.freeform`, `.original`) or the stored dimensions are unusable.
    public var fixedRatio: Double? {
        switch self {
        case .freeform, .original:
            return nil
        case .square:
            return 1
        case .custom(let width, let height):
            guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
            return width / height
        }
    }
}
