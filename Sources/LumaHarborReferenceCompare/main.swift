import CoreGraphics
import Darwin
import Foundation
import ImageIO
import RawProcessingCore

private struct MatrixCase: Decodable {
    let fixtureID: String
    let rawID: String
    let lrNeutralID: String
    let lrPresetID: String
    let lhNeutralID: String
    let lhPresetID: String
    let profile: String
    let processVersion: String
    let colorSpace: String
    let bitDepth: Int
    let width: Int
    let height: Int
}

private struct ReferenceMatrix: Decodable {
    let schemaVersion: Int
    let cases: [MatrixCase]
}

private struct NormalizedImage {
    let width: Int
    let height: Int
    let pixels: [SIMD4<Float>]
}

private struct MetricsOutput: Encodable {
    let meanAbsoluteEffectError: Double
    let p95AbsoluteEffectError: Double
    let luminanceEffectSSIM: Double
    let sampleCount: Int
}

private struct ComparisonOutput: Encodable {
    let status: String
    let caseID: String?
    let width: Int?
    let height: Int?
    let metrics: MetricsOutput?
    let reason: String?
}

private enum CommandFailure {
    case notRun
    case invalidArguments
    case invalidMatrix
    case matrixMismatch
    case unsupportedImage
    case dimensionMismatch
    case comparisonFailed
}

private let imageExtensions = ["tiff", "tif", "png", "jpg", "jpeg"]
private let meanErrorThreshold = 0.02
private let p95ErrorThreshold = 0.05
private let ssimThreshold = 0.98

private func printJSON(_ output: ComparisonOutput) -> Never {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    if let data = try? encoder.encode(output), let string = String(data: data, encoding: .utf8) {
        print(string)
    } else {
        print("{\"status\":\"FAIL\",\"reason\":\"output encoding failed\"}")
    }
    exit(output.status == "PASS" ? 0 : 1)
}

private func fail(_ failure: CommandFailure, caseID: String? = nil) -> Never {
    let status: String
    let reason: String
    switch failure {
    case .notRun:
        status = "NOT RUN"
        reason = "reference image unavailable"
    case .invalidArguments:
        status = "FAIL"
        reason = "invalid arguments"
    case .invalidMatrix:
        status = "FAIL"
        reason = "invalid reference matrix"
    case .matrixMismatch:
        status = "FAIL"
        reason = "matrix ID mismatch"
    case .unsupportedImage:
        status = "FAIL"
        reason = "unsupported reference image"
    case .dimensionMismatch:
        status = "FAIL"
        reason = "reference dimensions do not match"
    case .comparisonFailed:
        status = "FAIL"
        reason = "reference comparison failed"
    }
    printJSON(ComparisonOutput(status: status, caseID: caseID, width: nil, height: nil, metrics: nil, reason: reason))
}

private func usage() -> Never {
    print("usage: LumaHarborReferenceCompare --case <id> --lr-neutral <id> --lr-preset <id> --lh-neutral <id> --lh-preset <id> --matrix <file> --images <directory>")
    exit(0)
}

private func arguments() -> [String: String] {
    let values = Array(CommandLine.arguments.dropFirst())
    if values.contains("--help") { usage() }
    guard values.count % 2 == 0 else { fail(.invalidArguments) }
    var parsed: [String: String] = [:]
    var index = 0
    while index < values.count {
        let key = values[index]
        let value = values[index + 1]
        guard key.hasPrefix("--"), !value.hasPrefix("--"), parsed[key] == nil else {
            fail(.invalidArguments)
        }
        parsed[key] = value
        index += 2
    }
    return parsed
}

private func loadMatrix(at path: String) -> ReferenceMatrix? {
    guard let data = FileManager.default.contents(atPath: path),
          let matrix = try? JSONDecoder().decode(ReferenceMatrix.self, from: data),
          matrix.schemaVersion == 1,
          matrix.cases.count == 5 else {
        return nil
    }
    return matrix
}

private func imageURL(for identifier: String, in directory: URL) -> URL? {
    imageExtensions
        .map { directory.appendingPathComponent("\(identifier).\($0)") }
        .first(where: { FileManager.default.fileExists(atPath: $0.path) })
}

private func loadImage(at url: URL) -> NormalizedImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          image.width > 0,
          image.height > 0,
          let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
        return nil
    }

    let width = image.width
    let height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let baseAddress = buffer.baseAddress,
              let context = CGContext(
                  data: baseAddress,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: bitmapInfo
              ) else {
            return false
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard rendered else { return nil }

    var pixels: [SIMD4<Float>] = []
    pixels.reserveCapacity(width * height)
    for index in stride(from: 0, to: bytes.count, by: 4) {
        pixels.append(SIMD4(
            Float(bytes[index]) / 255,
            Float(bytes[index + 1]) / 255,
            Float(bytes[index + 2]) / 255,
            Float(bytes[index + 3]) / 255
        ))
    }
    return NormalizedImage(width: width, height: height, pixels: pixels)
}

let parsed = arguments()
let requiredKeys = ["--case", "--lr-neutral", "--lr-preset", "--lh-neutral", "--lh-preset", "--matrix", "--images"]
guard requiredKeys.allSatisfy({ parsed[$0] != nil }),
      let caseID = parsed["--case"],
      let matrixPath = parsed["--matrix"],
      let imageDirectoryPath = parsed["--images"],
      let matrix = loadMatrix(at: matrixPath),
      let matrixCase = matrix.cases.first(where: { $0.fixtureID == caseID }) else {
    fail(.invalidMatrix)
}

guard matrixCase.lrNeutralID == parsed["--lr-neutral"],
      matrixCase.lrPresetID == parsed["--lr-preset"],
      matrixCase.lhNeutralID == parsed["--lh-neutral"],
      matrixCase.lhPresetID == parsed["--lh-preset"] else {
    fail(.matrixMismatch, caseID: caseID)
}

let imageDirectory = URL(fileURLWithPath: imageDirectoryPath, isDirectory: true)
let identifiers = [
    parsed["--lr-neutral"]!, parsed["--lr-preset"]!,
    parsed["--lh-neutral"]!, parsed["--lh-preset"]!
]
let optionalURLs = identifiers.map { imageURL(for: $0, in: imageDirectory) }
guard optionalURLs.allSatisfy({ $0 != nil }) else {
    fail(.notRun, caseID: caseID)
}
let urls = optionalURLs.compactMap { $0 }
private let optionalImages = urls.map(loadImage)
guard optionalImages.allSatisfy({ $0 != nil }) else {
    fail(.unsupportedImage, caseID: caseID)
}
private let images = optionalImages.compactMap { $0 }
let firstSize = (images[0].width, images[0].height)
guard images.dropFirst().allSatisfy({ ($0.width, $0.height) == firstSize }) else {
    fail(.dimensionMismatch, caseID: caseID)
}

guard let result = try? ReferenceComparisonMetrics.compare(
    width: firstSize.0,
    height: firstSize.1,
    lrNeutral: images[0].pixels,
    lrPreset: images[1].pixels,
    lhNeutral: images[2].pixels,
    lhPreset: images[3].pixels
) else {
    fail(.comparisonFailed, caseID: caseID)
}

let passed = result.meanAbsoluteEffectError <= meanErrorThreshold
    && result.p95AbsoluteEffectError <= p95ErrorThreshold
    && result.luminanceEffectSSIM >= ssimThreshold
private let output = ComparisonOutput(
    status: passed ? "PASS" : "FAIL",
    caseID: caseID,
    width: firstSize.0,
    height: firstSize.1,
    metrics: MetricsOutput(
        meanAbsoluteEffectError: result.meanAbsoluteEffectError,
        p95AbsoluteEffectError: result.p95AbsoluteEffectError,
        luminanceEffectSSIM: result.luminanceEffectSSIM,
        sampleCount: result.sampleCount
    ),
    reason: nil
)
printJSON(output)
