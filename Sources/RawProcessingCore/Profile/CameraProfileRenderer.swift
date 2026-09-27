@preconcurrency import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

public enum CameraProfileRenderingError: Error, Equatable, Sendable {
    case profileMismatch
    case filterUnavailable
}

/// Core Image implementation of the public camera-profile fallback contract.
/// The matrix is applied first, followed by three monotonic 1D channel LUTs.
public struct CameraProfileRenderer: CameraProfileRendering, Sendable {
    public init() {}

    public func apply(
        _ fallback: CameraProfileFallback,
        to image: CIImage,
        recipe: ResolvedRawRenderRecipe
    ) throws -> CIImage {
        try fallback.validate()
        if let fallbackID = recipe.cameraProfile.fallbackID, fallbackID != fallback.id {
            throw CameraProfileRenderingError.profileMismatch
        }
        guard !fallback.isIdentity else { return image }

        var working = image
        if !Self.isIdentityMatrix(fallback.matrix3x3) {
            let matrix = CIFilter.colorMatrix()
            matrix.inputImage = working
            matrix.rVector = CIVector(x: CGFloat(fallback.matrix3x3[0]), y: CGFloat(fallback.matrix3x3[1]), z: CGFloat(fallback.matrix3x3[2]), w: 0)
            matrix.gVector = CIVector(x: CGFloat(fallback.matrix3x3[3]), y: CGFloat(fallback.matrix3x3[4]), z: CGFloat(fallback.matrix3x3[5]), w: 0)
            matrix.bVector = CIVector(x: CGFloat(fallback.matrix3x3[6]), y: CGFloat(fallback.matrix3x3[7]), z: CGFloat(fallback.matrix3x3[8]), w: 0)
            matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            guard let output = matrix.outputImage else { throw CameraProfileRenderingError.filterUnavailable }
            working = output
        }

        if !Self.isIdentityLUT(fallback.redToneLUT)
            || !Self.isIdentityLUT(fallback.greenToneLUT)
            || !Self.isIdentityLUT(fallback.blueToneLUT) {
            guard fallback.redToneLUT.count == fallback.greenToneLUT.count,
                  fallback.redToneLUT.count == fallback.blueToneLUT.count else {
                throw CameraProfileRenderingError.filterUnavailable
            }
            guard let output = Self.applyLUT(
                red: fallback.redToneLUT,
                green: fallback.greenToneLUT,
                blue: fallback.blueToneLUT,
                to: working
            ) else {
                throw CameraProfileRenderingError.filterUnavailable
            }
            working = output
        }
        return working
    }

    private static func isIdentityMatrix(_ matrix: [Float]) -> Bool {
        matrix == [1, 0, 0, 0, 1, 0, 0, 0, 1]
    }

    private static func isIdentityLUT(_ values: [Float]) -> Bool {
        values.count == 2 && values == [0, 1]
    }

    private static func applyLUT(
        red: [Float], green: [Float], blue: [Float], to image: CIImage
    ) -> CIImage? {
        let dimension = red.count
        guard dimension >= 2, dimension <= 64 else { return nil }
        var cube = [Float]()
        cube.reserveCapacity(dimension * dimension * dimension * 4)
        for blueIndex in 0..<dimension {
            for greenIndex in 0..<dimension {
                for redIndex in 0..<dimension {
                    cube.append(red[redIndex])
                    cube.append(green[greenIndex])
                    cube.append(blue[blueIndex])
                    cube.append(1)
                }
            }
        }
        let data = cube.withUnsafeBytes { Data($0) }
        let filter = CIFilter(name: "CIColorCube")
        filter?.setValue(image, forKey: kCIInputImageKey)
        filter?.setValue(dimension, forKey: "inputCubeDimension")
        filter?.setValue(data, forKey: "inputCubeData")
        return filter?.outputImage
    }
}

public protocol CameraProfileRendering: Sendable {
    func apply(
        _ fallback: CameraProfileFallback,
        to image: CIImage,
        recipe: ResolvedRawRenderRecipe
    ) throws -> CIImage
}
