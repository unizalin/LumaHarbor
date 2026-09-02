import CoreGraphics
import Foundation

/// Computes an RGB histogram directly from a rendered image's own pixels
/// (parity design spec §6.2). A pure function over a `CGImage` -- never tied
/// to `EditorSession`, a scheduler, or any async plumbing -- so it can be
/// unit-tested against tiny synthetic bitmaps with exactly known pixel
/// values, and so a caller decides on its own how (and whether) to run it
/// off the main actor (see `EditorDependencies.computeHistogram`).
public enum HistogramComputer {
    /// `nil` only when the image's pixels genuinely can't be read into an
    /// 8-bit RGBA buffer (e.g. a zero-sized image, or an exotic backing
    /// store `CGContext` refuses to draw into) -- never a crash.
    public static func histogram(for image: CGImage) -> HistogramData? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var pixelData = [UInt8](repeating: 0, count: bytesPerRow * height)

        let drew: Bool = pixelData.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                      data: baseAddress,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }

        var red = [Int](repeating: 0, count: HistogramData.binCount)
        var green = [Int](repeating: 0, count: HistogramData.binCount)
        var blue = [Int](repeating: 0, count: HistogramData.binCount)

        for pixelIndex in 0..<(width * height) {
            let offset = pixelIndex * bytesPerPixel
            red[Int(pixelData[offset])] += 1
            green[Int(pixelData[offset + 1])] += 1
            blue[Int(pixelData[offset + 2])] += 1
        }

        return HistogramData(red: red, green: green, blue: blue)
    }
}
