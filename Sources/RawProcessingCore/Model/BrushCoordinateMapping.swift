import CoreGraphics
import Foundation

/// Errors raised when source/display brush geometry cannot be mapped safely.
public enum BrushCoordinateMappingError: Error, Equatable, Sendable {
    case invalidExtent
    case nonInvertible
    case outsideSource
    case outsideDisplay
    case nonFinitePoint
}

/// The one authoritative mapping between normalized source coordinates (the
/// coordinates persisted by `BrushMask`) and the display frame produced by
/// `GeometryRenderer`.  The mapping intentionally rejects points outside the
/// visible crop instead of silently clamping them or falling back to identity.
public struct BrushCoordinateMapping: Equatable, Sendable {
    public let sourceExtent: CGRect
    public let displayExtent: CGRect
    public let geometry: GeometryAdjustments

    private let sourceToDisplayMatrix: Matrix3x3
    private let displayToSourceMatrix: Matrix3x3

    public init(sourceExtent: CGRect, geometry: GeometryAdjustments = .neutral) throws {
        guard sourceExtent.width.isFinite, sourceExtent.height.isFinite,
              sourceExtent.width > 0, sourceExtent.height > 0 else {
            throw BrushCoordinateMappingError.invalidExtent
        }
        self.sourceExtent = sourceExtent
        self.geometry = geometry

        var matrix = Matrix3x3.identity
        if geometry.flipHorizontal { matrix = Matrix3x3.scale(x: -1, y: 1, around: CGPoint(x: 0.5, y: 0.5)) * matrix }
        if geometry.flipVertical { matrix = Matrix3x3.scale(x: 1, y: -1, around: CGPoint(x: 0.5, y: 0.5)) * matrix }
        if geometry.rotationDegrees != 0 {
            matrix = Matrix3x3.rotationClockwise(degrees: geometry.rotationDegrees) * matrix
        }
        if geometry.straightenDegrees != 0 {
            matrix = Matrix3x3.rotationClockwise(degrees: geometry.straightenDegrees) * matrix
        }
        if geometry.perspectiveHorizontal != 0 || geometry.perspectiveVertical != 0 {
            let shortSide = min(sourceExtent.width, sourceExtent.height)
            let h = CGFloat(geometry.perspectiveHorizontal / 100) * shortSide * 0.25 / sourceExtent.width
            let v = CGFloat(geometry.perspectiveVertical / 100) * shortSide * 0.25 / sourceExtent.height
            let destination = [
                CGPoint(x: h, y: v), CGPoint(x: 1 - h, y: -v),
                CGPoint(x: 1 + h, y: 1 + v), CGPoint(x: -h, y: 1 - v)
            ]
            matrix = try Matrix3x3.homography(
                from: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)],
                to: destination
            ) * matrix
        }
        if let pins = geometry.cornerPins, !pins.isIdentity {
            matrix = try Matrix3x3.homography(
                from: [
                    CGPoint(x: pins.topLeft.x, y: pins.topLeft.y),
                    CGPoint(x: pins.topRight.x, y: pins.topRight.y),
                    CGPoint(x: pins.bottomRight.x, y: pins.bottomRight.y),
                    CGPoint(x: pins.bottomLeft.x, y: pins.bottomLeft.y)
                ],
                to: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
            ) * matrix
        }
        if let crop = geometry.crop, !crop.isFull {
            let cropMatrix = Matrix3x3.translation(x: -crop.x, y: -crop.y)
                * Matrix3x3.scale(x: 1 / crop.width, y: 1 / crop.height)
            matrix = cropMatrix * matrix
        }
        guard let inverse = matrix.inverted else { throw BrushCoordinateMappingError.nonInvertible }
        self.sourceToDisplayMatrix = matrix
        self.displayToSourceMatrix = inverse

        var displayWidth = sourceExtent.width
        var displayHeight = sourceExtent.height
        if geometry.rotationDegrees == 90 || geometry.rotationDegrees == 270 {
            swap(&displayWidth, &displayHeight)
        }
        if let crop = geometry.crop, !crop.isFull {
            displayWidth *= crop.width
            displayHeight *= crop.height
        }
        self.displayExtent = CGRect(x: sourceExtent.minX, y: sourceExtent.minY,
                                    width: displayWidth, height: displayHeight)
    }

    public init(sourceSize: CGSize, geometry: GeometryAdjustments = .neutral) throws {
        try self.init(sourceExtent: CGRect(origin: .zero, size: sourceSize), geometry: geometry)
    }

    /// Maps normalized source coordinates to display pixel coordinates.
    public func sourceToDisplay(_ point: CGPoint) throws -> CGPoint {
        guard point.x.isFinite, point.y.isFinite else { throw BrushCoordinateMappingError.nonFinitePoint }
        guard point.x >= 0, point.x <= 1, point.y >= 0, point.y <= 1 else { throw BrushCoordinateMappingError.outsideSource }
        let normalized = sourceToDisplayMatrix.apply(point)
        guard normalized.x.isFinite, normalized.y.isFinite,
              normalized.x >= -1e-8, normalized.x <= 1 + 1e-8,
              normalized.y >= -1e-8, normalized.y <= 1 + 1e-8 else {
            throw BrushCoordinateMappingError.outsideDisplay
        }
        return CGPoint(
            x: displayExtent.minX + normalized.x * displayExtent.width,
            y: displayExtent.minY + normalized.y * displayExtent.height
        )
    }

    /// Maps display pixel coordinates back to normalized source coordinates.
    public func displayToSource(_ point: CGPoint) throws -> CGPoint {
        guard point.x.isFinite, point.y.isFinite else { throw BrushCoordinateMappingError.nonFinitePoint }
        let normalized = CGPoint(
            x: (point.x - displayExtent.minX) / displayExtent.width,
            y: (point.y - displayExtent.minY) / displayExtent.height
        )
        guard normalized.x >= -1e-8, normalized.x <= 1 + 1e-8,
              normalized.y >= -1e-8, normalized.y <= 1 + 1e-8 else {
            throw BrushCoordinateMappingError.outsideDisplay
        }
        let source = displayToSourceMatrix.apply(normalized)
        guard source.x.isFinite, source.y.isFinite,
              source.x >= -1e-8, source.x <= 1 + 1e-8,
              source.y >= -1e-8, source.y <= 1 + 1e-8 else {
            throw BrushCoordinateMappingError.outsideSource
        }
        return CGPoint(x: min(max(source.x, 0), 1), y: min(max(source.y, 0), 1))
    }

    public func forward(_ point: CGPoint) throws -> CGPoint { try sourceToDisplay(point) }
    public func inverse(_ point: CGPoint) throws -> CGPoint { try displayToSource(point) }
    public func mapSourceToDisplay(_ point: CGPoint) throws -> CGPoint { try sourceToDisplay(point) }
    public func mapDisplayToSource(_ point: CGPoint) throws -> CGPoint { try displayToSource(point) }

    public func sourceToDisplay(_ point: BrushMaskPoint) throws -> CGPoint {
        try sourceToDisplay(CGPoint(x: point.x, y: point.y))
    }

    /// Converts a normalized source point to the source image's pixel frame.
    /// This is used while the brush stage is still before geometry; callers
    /// should use `sourceToDisplay` once geometry has been rendered.
    public func sourceToSourcePixel(_ point: BrushMaskPoint) throws -> CGPoint {
        _ = try sourceToDisplay(point) // validates crop/geometry visibility
        return CGPoint(x: sourceExtent.minX + point.x * sourceExtent.width,
                       y: sourceExtent.minY + point.y * sourceExtent.height)
    }

    private struct Matrix3x3: Equatable, Sendable {
        var m: [Double]
        static let identity = Matrix3x3(m: [1,0,0, 0,1,0, 0,0,1])

        static func * (lhs: Matrix3x3, rhs: Matrix3x3) -> Matrix3x3 {
            var out = [Double](repeating: 0, count: 9)
            for row in 0..<3 { for col in 0..<3 {
                out[row * 3 + col] = (0..<3).reduce(0) { $0 + lhs.m[row * 3 + $1] * rhs.m[$1 * 3 + col] }
            }}
            return Matrix3x3(m: out)
        }

        static func translation(x: CGFloat, y: CGFloat) -> Matrix3x3 {
            Matrix3x3(m: [1,0,Double(x), 0,1,Double(y), 0,0,1])
        }
        static func scale(x: CGFloat, y: CGFloat) -> Matrix3x3 {
            Matrix3x3(m: [Double(x),0,0, 0,Double(y),0, 0,0,1])
        }
        static func scale(x: CGFloat, y: CGFloat, around center: CGPoint) -> Matrix3x3 {
            translation(x: center.x, y: center.y) * scale(x: x, y: y) * translation(x: -center.x, y: -center.y)
        }
        static func rotationClockwise(degrees: Double) -> Matrix3x3 {
            // Normalized brush coordinates use a top-left, y-down frame;
            // positive photo rotation is clockwise in that frame.
            let r = degrees * .pi / 180
            let c = cos(r), s = sin(r)
            return translation(x: 0.5, y: 0.5) * Matrix3x3(m: [c,-s,0, s,c,0, 0,0,1]) * translation(x: -0.5, y: -0.5)
        }

        func apply(_ point: CGPoint) -> CGPoint {
            let x = Double(point.x), y = Double(point.y)
            let w = m[6] * x + m[7] * y + m[8]
            let safeW = abs(w) < 1e-12 ? (w < 0 ? -1e-12 : 1e-12) : w
            return CGPoint(x: (m[0] * x + m[1] * y + m[2]) / safeW,
                           y: (m[3] * x + m[4] * y + m[5]) / safeW)
        }

        var inverted: Matrix3x3? {
            let a=m[0], b=m[1], c=m[2], d=m[3], e=m[4], f=m[5], g=m[6], h=m[7], i=m[8]
            let determinant = a*(e*i-f*h) - b*(d*i-f*g) + c*(d*h-e*g)
            guard determinant.isFinite, abs(determinant) > 1e-12 else { return nil }
            let inv = [
                (e*i-f*h), (c*h-b*i), (b*f-c*e),
                (f*g-d*i), (a*i-c*g), (c*d-a*f),
                (d*h-e*g), (b*g-a*h), (a*e-b*d)
            ].map { $0 / determinant }
            return Matrix3x3(m: inv)
        }

        static func homography(from source: [CGPoint], to destination: [CGPoint]) throws -> Matrix3x3 {
            guard source.count == 4, destination.count == 4 else { throw BrushCoordinateMappingError.nonInvertible }
            var a = Array(repeating: Array(repeating: 0.0, count: 8), count: 8)
            var b = Array(repeating: 0.0, count: 8)
            for index in 0..<4 {
                let x = Double(source[index].x), y = Double(source[index].y)
                let u = Double(destination[index].x), v = Double(destination[index].y)
                let row = index * 2
                a[row] = [x,y,1, 0,0,0, -u*x, -u*y]
                a[row + 1] = [0,0,0, x,y,1, -v*x, -v*y]
                b[row] = u; b[row + 1] = v
            }
            // Gaussian elimination over the eight unknowns h00...h21; h22=1.
            for col in 0..<8 {
                guard let pivot = (col..<8).max(by: { abs(a[$0][col]) < abs(a[$1][col]) }), abs(a[pivot][col]) > 1e-12 else {
                    throw BrushCoordinateMappingError.nonInvertible
                }
                if pivot != col { a.swapAt(pivot, col); b.swapAt(pivot, col) }
                let divisor = a[col][col]
                for j in col..<8 { a[col][j] /= divisor }
                b[col] /= divisor
                for row in 0..<8 where row != col {
                    let factor = a[row][col]
                    guard factor != 0 else { continue }
                    for j in col..<8 { a[row][j] -= factor * a[col][j] }
                    b[row] -= factor * b[col]
                }
            }
            return Matrix3x3(m: [b[0],b[1],b[2], b[3],b[4],b[5], b[6],b[7],1])
        }
    }
}
