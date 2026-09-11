import CoreGraphics
@preconcurrency import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Renders professional review overlays (highlight/shadow clipping, gamut warning)
/// and soft-proofing color conversions.
/// Spec §7.4. All operations are non-destructive and transient for preview only.
public struct ProfessionalPreviewRenderer: Sendable {
    public init() {}

    private static let overlayKernel: CIColorKernel? = {
        guard let url = Bundle.module.url(forResource: "CoreImageKernels", withExtension: "metallib"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? CIColorKernel(functionName: "professionalPreviewOverlay", fromMetalLibraryData: data)
    }()

    public static func apply(
        _ options: ProfessionalPreviewOptions,
        to image: CIImage
    ) -> CIImage {
        guard options.isActive else { return image }
        var working = image

        // 1. Soft proof
        if let profile = options.softProofProfile {
            working = applySoftProof(profile, to: working)
        }

        // 2. Overlays
        if options.showHighlightClipping || options.showShadowClipping || options.showGamutWarning {
            working = applyOverlays(options, to: working)
        }

        return working
    }

    public static func targetColorSpace(for profile: SoftProofProfile) -> CGColorSpace? {
        switch profile {
        case .sRGB:
            return CGColorSpace(name: CGColorSpace.sRGB)
        case .displayP3:
            return CGColorSpace(name: CGColorSpace.displayP3)
        case .adobeRGB:
            return CGColorSpace(name: CGColorSpace.adobeRGB1998)
        }
    }

    private static func applySoftProof(_ profile: SoftProofProfile, to image: CIImage) -> CIImage {
        guard let colorSpace = targetColorSpace(for: profile) else { return image }
        // Simulate gamut reduction by mapping to destination space and then mapping back to working space for preview
        if let proofed = image.matchedFromWorkingSpace(to: colorSpace)?.matchedToWorkingSpace(from: colorSpace) {
            return proofed
        }
        return image
    }

    private static func applyOverlays(_ options: ProfessionalPreviewOptions, to image: CIImage) -> CIImage {
        let extent = image.extent

        if let kernel = overlayKernel {
            let hl = Float(options.showHighlightClipping ? 1.0 : 0.0)
            let sh = Float(options.showShadowClipping ? 1.0 : 0.0)
            let gm = Float(options.showGamutWarning ? 1.0 : 0.0)

            if let result = kernel.apply(
                extent: extent,
                arguments: [image, hl, sh, gm]
            ) {
                return result
            }
        }

        // Fallback when Metal kernel is unavailable
        return applyFallbackOverlays(options, to: image)
    }

    private static func applyFallbackOverlays(_ options: ProfessionalPreviewOptions, to image: CIImage) -> CIImage {
        var result = image
        let extent = image.extent

        // Highlight clipping (pure red indicator)
        if options.showHighlightClipping {
            let clamp = CIFilter.colorClamp()
            clamp.inputImage = image
            clamp.minComponents = CIVector(x: 0.99, y: 0.99, z: 0.99, w: 0)
            clamp.maxComponents = CIVector(x: 1.0, y: 1.0, z: 1.0, w: 1)
            if let clamped = clamp.outputImage {
                let matrix = CIFilter.colorMatrix()
                matrix.inputImage = clamped
                matrix.rVector = CIVector(x: 100, y: 100, z: 100, w: 0)
                matrix.biasVector = CIVector(x: -99, y: 0, z: 0, w: 0)
                if let mask = matrix.outputImage {
                    let redColor = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: extent)
                    let blend = CIFilter.blendWithMask()
                    blend.inputImage = redColor
                    blend.backgroundImage = result
                    blend.maskImage = mask
                    if let blended = blend.outputImage {
                        result = blended
                    }
                }
            }
        }

        // Shadow clipping (pure blue indicator)
        if options.showShadowClipping {
            let invert = CIFilter.colorInvert()
            invert.inputImage = image
            if let inverted = invert.outputImage {
                let clamp = CIFilter.colorClamp()
                clamp.inputImage = inverted
                clamp.minComponents = CIVector(x: 0.99, y: 0.99, z: 0.99, w: 0)
                clamp.maxComponents = CIVector(x: 1.0, y: 1.0, z: 1.0, w: 1)
                if let clamped = clamp.outputImage {
                    let blueColor = CIImage(color: CIColor(red: 0, green: 0.2, blue: 1)).cropped(to: extent)
                    let blend = CIFilter.blendWithMask()
                    blend.inputImage = blueColor
                    blend.backgroundImage = result
                    blend.maskImage = clamped
                    if let blended = blend.outputImage {
                        result = blended
                    }
                }
            }
        }

        return result
    }
}
