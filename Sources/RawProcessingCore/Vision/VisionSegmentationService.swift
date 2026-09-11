@preconcurrency import CoreImage
import CoreGraphics
import CryptoKit
import Foundation
#if canImport(Vision)
import Vision
#endif

/// Offline, on-device subject / foreground segmentation using Apple's Vision framework
/// (design spec §6.5, §17: `VNGenerateForegroundInstanceMaskRequest`).
///
/// Guaranteed:
/// 1. Runs completely offline; never connects to any network or remote service.
/// 2. Does not log private file paths, accounts, or credentials.
/// 3. In environments where Vision instance mask is unavailable or fails, returns a safe,
///    deterministic fallback mask rather than crashing or mutating edits.
public enum VisionSegmentationService {
    /// Vision request revision tracking
    public static let currentVisionRevision: Int = 1

    /// Computes SHA-256 hex digest of image data
    public static func computeDigest(of data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Generates a normalized grayscale foreground (subject) mask CIImage.
    /// Pixels are 1.0 for foreground subject and 0.0 for background.
    public static func generateForegroundMask(for image: CIImage) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else {
            return CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        }

        #if canImport(Vision)
        if #available(macOS 14.0, iOS 17.0, *) {
            if let mask = performVisionSegmentation(image: image) {
                return mask
            }
        }
        #endif

        return fallbackSubjectMask(extent: extent)
    }

    #if canImport(Vision)
    @available(macOS 14.0, iOS 17.0, *)
    private static func performVisionSegmentation(image: CIImage) -> CIImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        do {
            try handler.perform([request])
            guard let result = request.results?.first else { return nil }
            let allInstances = result.allInstances
            guard !allInstances.isEmpty else { return nil }
            let maskPixelBuffer = try result.generateScaledMaskForImage(forInstances: allInstances, from: handler)
            let rawMask = CIImage(cvPixelBuffer: maskPixelBuffer)
            // Scale mask to source extent
            let scaleX = extentScale(from: rawMask.extent.width, to: image.extent.width)
            let scaleY = extentScale(from: rawMask.extent.height, to: image.extent.height)
            let scaled = rawMask.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            return scaled.cropped(to: image.extent)
        } catch {
            return nil
        }
    }

    private static func extentScale(from: CGFloat, to: CGFloat) -> CGFloat {
        guard from > 0 else { return 1.0 }
        return to / from
    }
    #endif

    /// Safe deterministic fallback when Vision is unsupported or fails in headless test runners.
    /// Creates a centered subject-weighted elliptical mask.
    public static func fallbackSubjectMask(extent: CGRect) -> CIImage {
        let center = CGPoint(x: extent.midX, y: extent.midY)
        let radiusX = extent.width * 0.35
        let radiusY = extent.height * 0.45
        let maxRadius = max(radiusX, radiusY)

        // Radial gradient centered on the frame
        guard let filter = CIFilter(name: "CIRadialGradient") else {
            return CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1)).cropped(to: extent)
        }
        filter.setValue(CIVector(cgPoint: center), forKey: "inputCenter")
        filter.setValue(Float(maxRadius * 0.2), forKey: "inputRadius0")
        filter.setValue(Float(maxRadius), forKey: "inputRadius1")
        filter.setValue(CIColor(red: 1, green: 1, blue: 1, alpha: 1), forKey: "inputColor0")
        filter.setValue(CIColor(red: 0, green: 0, blue: 0, alpha: 0), forKey: "inputColor1")

        guard let output = filter.outputImage else {
            return CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1)).cropped(to: extent)
        }
        return output.cropped(to: extent)
    }
}
