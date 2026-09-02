import Foundation

/// An RGB histogram over an image's actually-rendered pixels (parity design
/// spec §6.2: the histogram "must reflect the current rendered preview, not
/// just original-file statistics"). `binCount` is fixed at 256 -- one bin
/// per 8-bit tonal value, matching the 8-bit-per-component preview pixels
/// `HistogramComputer` samples.
public struct HistogramData: Equatable, Sendable {
    public static let binCount = 256

    public var red: [Int]
    public var green: [Int]
    public var blue: [Int]

    public init(red: [Int], green: [Int], blue: [Int]) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Every bin at zero -- the safe placeholder before any preview has
    /// rendered, distinct from an actual all-black image's histogram (which
    /// would instead spike bin 0 to the pixel count, not read as "empty").
    public static let empty = HistogramData(
        red: Array(repeating: 0, count: binCount),
        green: Array(repeating: 0, count: binCount),
        blue: Array(repeating: 0, count: binCount)
    )
}
