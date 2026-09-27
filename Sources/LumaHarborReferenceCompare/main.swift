import CoreGraphics
import Darwin
import Foundation
import RawProcessingCore

private struct MatrixCase: Decodable {
    let caseID: String
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

private struct LoadedReference {
    let width: Int
    let height: Int
    let hasAlpha: Bool
    let reader: ReferenceImageTileReader
}

private struct MetricsOutput: Encodable {
    let meanAbsoluteError: Double
    let p95AbsoluteError: Double
    let luminanceSSIM: Double
    let highlightClippingFractionDelta: Double
    let shadowClippingFractionDelta: Double
    let sampleCount: Int
}

private struct ThresholdsOutput: Encodable {
    let version: Int
    let meanAbsoluteError: Double
    let p95AbsoluteError: Double
    let luminanceSSIM: Double
    let highlightClippingFractionDelta: Double
    let shadowClippingFractionDelta: Double
}

private struct EvaluationOutput: Encodable {
    let meanAbsoluteErrorPassed: Bool
    let p95AbsoluteErrorPassed: Bool
    let luminanceSSIMPassed: Bool
    let highlightClippingFractionDeltaPassed: Bool
    let shadowClippingFractionDeltaPassed: Bool
    let isPassing: Bool
}

private struct ComparisonOutput: Encodable {
    let status: String
    let mode: ReferenceComparisonMode?
    let caseID: String?
    let rawID: String?
    let width: Int?
    let height: Int?
    let metrics: MetricsOutput?
    let thresholds: ThresholdsOutput?
    let evaluation: EvaluationOutput?
    let reason: String?
}

private struct BatchCaseOutput: Encodable {
    let status: String
    let rawID: String
    let caseID: String
    let width: Int?
    let height: Int?
    let metrics: MetricsOutput?
    let evaluation: EvaluationOutput?
    let reason: String?
}

private struct BatchOutput: Encodable {
    let status: String
    let mode: ReferenceComparisonMode
    let cases: [BatchCaseOutput]
    let thresholds: ThresholdsOutput
}

private struct ParsedArguments {
    let values: [String: String]
    let flags: Set<String>
}

private struct EvaluatedCase {
    let width: Int
    let height: Int
    let result: ReferenceComparisonResult
    let evaluation: LightroomReferenceThresholds.Evaluation
}

private func currentThresholdsOutput() -> ThresholdsOutput {
    let thresholds = LightroomReferenceThresholds.current
    return ThresholdsOutput(
        version: thresholds.version,
        meanAbsoluteError: thresholds.meanAbsoluteEffectError,
        p95AbsoluteError: thresholds.p95AbsoluteEffectError,
        luminanceSSIM: thresholds.luminanceEffectSSIM,
        highlightClippingFractionDelta: thresholds.highlightClippingFractionDelta,
        shadowClippingFractionDelta: thresholds.shadowClippingFractionDelta
    )
}

private func metricsOutput(for result: ReferenceComparisonResult) -> MetricsOutput {
    MetricsOutput(
        meanAbsoluteError: result.meanAbsoluteError,
        p95AbsoluteError: result.p95AbsoluteError,
        luminanceSSIM: result.luminanceSSIM,
        highlightClippingFractionDelta: result.highlightClippingFractionDelta,
        shadowClippingFractionDelta: result.shadowClippingFractionDelta,
        sampleCount: result.sampleCount
    )
}

private func evaluationOutput(for evaluation: LightroomReferenceThresholds.Evaluation) -> EvaluationOutput {
    EvaluationOutput(
        meanAbsoluteErrorPassed: evaluation.meanAbsoluteEffectErrorPassed,
        p95AbsoluteErrorPassed: evaluation.p95AbsoluteEffectErrorPassed,
        luminanceSSIMPassed: evaluation.luminanceEffectSSIMPassed,
        highlightClippingFractionDeltaPassed: evaluation.highlightClippingFractionDeltaPassed,
        shadowClippingFractionDeltaPassed: evaluation.shadowClippingFractionDeltaPassed,
        isPassing: evaluation.isPassing
    )
}

private enum CommandFailure: Error {
    case notRun
    case invalidArguments
    case invalidMatrix
    case matrixMismatch
    case ambiguousImage
    case unsupportedImage
    case dimensionMismatch
    case comparisonFailed
    case invalidReportDestination
}

private func printJSON<T: Encodable>(_ output: T, status: String) -> Never {
    printJSON(output, status: status, reportURL: nil)
}

private func printJSON<T: Encodable>(_ output: T, status: String, reportURL: URL?) -> Never {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    if let data = try? encoder.encode(output), let string = String(data: data, encoding: .utf8) {
        if let reportURL {
            do {
                try data.write(to: reportURL, options: [.atomic])
            } catch {
                print("{\"status\":\"FAIL\",\"reason\":\"report write failed\"}")
                exit(1)
            }
        }
        print(string)
    } else {
        print("{\"status\":\"FAIL\",\"reason\":\"output encoding failed\"}")
    }
    exit(status == "PASS" ? 0 : 1)
}

private func fail(
    _ failure: CommandFailure,
    mode: ReferenceComparisonMode? = nil,
    caseID: String? = nil,
    rawID: String? = nil
) -> Never {
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
    case .ambiguousImage:
        status = "FAIL"
        reason = "ambiguous reference image"
    case .unsupportedImage:
        status = "FAIL"
        reason = "unsupported reference image"
    case .dimensionMismatch:
        status = "FAIL"
        reason = "reference dimensions do not match"
    case .comparisonFailed:
        status = "FAIL"
        reason = "reference comparison failed"
    case .invalidReportDestination:
        status = "FAIL"
        reason = "invalid report destination"
    }
    printJSON(ComparisonOutput(
        status: status,
        mode: mode,
        caseID: caseID,
        rawID: rawID,
        width: nil,
        height: nil,
        metrics: nil,
        thresholds: currentThresholdsOutput(),
        evaluation: nil,
        reason: reason
    ), status: status)
}

private func usage() -> Never {
    print("usage: LumaHarborReferenceCompare --all-neutral --matrix <file> --images <directory> [--report <file>]")
    print("   or: LumaHarborReferenceCompare --mode <neutralDirect|presetEffect|finalDirect> --case <id> --lr-neutral <id> --lr-preset <id> --lh-neutral <id> --lh-preset <id> --matrix <file> --images <directory> [--report <file>]")
    exit(0)
}

private func arguments() -> ParsedArguments {
    let values = Array(CommandLine.arguments.dropFirst())
    if values.contains("--help") { usage() }
    var parsedValues: [String: String] = [:]
    var parsedFlags = Set<String>()
    var index = 0
    while index < values.count {
        let key = values[index]
        guard key.hasPrefix("--"), parsedValues[key] == nil, !parsedFlags.contains(key) else {
            fail(.invalidArguments)
        }
        if key == "--all-neutral" {
            parsedFlags.insert(key)
            index += 1
            continue
        }
        guard index + 1 < values.count else { fail(.invalidArguments) }
        let value = values[index + 1]
        guard !value.hasPrefix("--") else { fail(.invalidArguments) }
        parsedValues[key] = value
        index += 2
    }
    return ParsedArguments(values: parsedValues, flags: parsedFlags)
}

private func loadMatrix(at path: String) -> ReferenceMatrix? {
    guard let data = FileManager.default.contents(atPath: path),
          let matrix = try? JSONDecoder().decode(ReferenceMatrix.self, from: data),
          matrix.schemaVersion == 2,
          matrix.cases.count == 20 else {
        return nil
    }
    let expectedRawIDs = Set(["raw-a", "raw-b", "raw-c", "raw-d"])
    let expectedFixtureIDs = Set(["fixture-a", "fixture-b", "fixture-c", "fixture-d", "fixture-e"])
    guard Set(matrix.cases.map(\.rawID)) == expectedRawIDs,
          Set(matrix.cases.map(\.fixtureID)) == expectedFixtureIDs,
          matrix.cases.allSatisfy({ item in
              item.caseID == "\(item.rawID)--\(item.fixtureID)"
                  && expectedRawIDs.contains(item.rawID)
                  && expectedFixtureIDs.contains(item.fixtureID)
                  && item.bitDepth == 16
                  && item.width > 0
                  && item.height > 0
                  && item.colorSpace == "sRGB"
                  && item.profile != "record-after-reference-export"
          }) else {
        return nil
    }
    return matrix
}

private func loadReference(
    identifier: String,
    matrixCase: MatrixCase,
    in directory: URL
) throws -> LoadedReference {
    let url = try ReferenceImageLocator.resolve(identifier: identifier, in: directory)
    let reader = try ReferenceImageTileReader(url: url)
    guard reader.width == matrixCase.width,
          reader.height == matrixCase.height,
          reader.bitsPerComponent == matrixCase.bitDepth,
          reader.colorSpaceIdentifier == (CGColorSpace.sRGB as String) else {
        throw CommandFailure.dimensionMismatch
    }
    return LoadedReference(
        width: reader.width,
        height: reader.height,
        hasAlpha: reader.hasAlpha,
        reader: reader
    )
}

private func evaluate(
    mode: ReferenceComparisonMode,
    matrixCase: MatrixCase,
    in directory: URL
) throws -> EvaluatedCase {
    let lrNeutral = try loadReference(identifier: matrixCase.lrNeutralID, matrixCase: matrixCase, in: directory)
    let lhNeutral = try loadReference(identifier: matrixCase.lhNeutralID, matrixCase: matrixCase, in: directory)
    let lrPreset: LoadedReference
    let lhPreset: LoadedReference
    if mode == .neutralDirect {
        // Batch neutral mode intentionally requires only the neutral pair.
        lrPreset = lrNeutral
        lhPreset = lhNeutral
    } else {
        lrPreset = try loadReference(identifier: matrixCase.lrPresetID, matrixCase: matrixCase, in: directory)
        lhPreset = try loadReference(identifier: matrixCase.lhPresetID, matrixCase: matrixCase, in: directory)
    }
    guard Set([lrNeutral.hasAlpha, lrPreset.hasAlpha, lhNeutral.hasAlpha, lhPreset.hasAlpha]).count == 1 else {
        throw CommandFailure.dimensionMismatch
    }
    guard let result = try? ReferenceComparisonMetrics.compareStreaming(
        mode: mode,
        lrNeutral: lrNeutral.reader,
        lrPreset: lrPreset.reader,
        lhNeutral: lhNeutral.reader,
        lhPreset: lhPreset.reader,
        tileHeight: 64
    ) else {
        throw CommandFailure.comparisonFailed
    }
    return EvaluatedCase(
        width: matrixCase.width,
        height: matrixCase.height,
        result: result,
        evaluation: LightroomReferenceThresholds.current.evaluate(result)
    )
}

private func resolveFailure(_ error: Error) -> CommandFailure {
    if let locatorError = error as? ReferenceImageLocatorError {
        switch locatorError {
        case .notFound: return .notRun
        case .ambiguous: return .ambiguousImage
        }
    }
    if let commandFailure = error as? CommandFailure {
        return commandFailure
    }
    return .unsupportedImage
}

private let parsed = arguments()
guard let matrixPath = parsed.values["--matrix"],
      let imageDirectoryPath = parsed.values["--images"],
      let matrix = loadMatrix(at: matrixPath) else {
    fail(.invalidMatrix)
}
let imageDirectory = URL(fileURLWithPath: imageDirectoryPath, isDirectory: true)
let reportURL = parsed.values["--report"].map { URL(fileURLWithPath: $0) }
if let reportURL {
    do {
        try ReferenceCompareOutputPathValidator.validate(
            reportURL: reportURL,
            matrixURL: URL(fileURLWithPath: matrixPath),
            referenceRootURL: imageDirectory
        )
    } catch {
        fail(.invalidReportDestination)
    }
}

if parsed.flags.contains("--all-neutral") {
    guard parsed.values.keys.allSatisfy({ $0 == "--matrix" || $0 == "--images" || $0 == "--report" }) else {
        fail(.invalidArguments)
    }
    let mode: ReferenceComparisonMode = .neutralDirect
    let rawIDs = ["raw-a", "raw-b", "raw-c", "raw-d"]
    var cases: [BatchCaseOutput] = []
    for rawID in rawIDs {
        guard let matrixCase = matrix.cases
            .filter({ $0.rawID == rawID })
            .sorted(by: { $0.caseID < $1.caseID })
            .first else {
            cases.append(BatchCaseOutput(
                status: "NOT RUN",
                rawID: rawID,
                caseID: "\(rawID)--fixture-a",
                width: nil,
                height: nil,
                metrics: nil,
                evaluation: nil,
                reason: "reference matrix case unavailable"
            ))
            continue
        }
        do {
            let evaluated = try evaluate(mode: mode, matrixCase: matrixCase, in: imageDirectory)
            cases.append(BatchCaseOutput(
                status: evaluated.evaluation.isPassing ? "PASS" : "FAIL",
                rawID: rawID,
                caseID: matrixCase.caseID,
                width: evaluated.width,
                height: evaluated.height,
                metrics: metricsOutput(for: evaluated.result),
                evaluation: evaluationOutput(for: evaluated.evaluation),
                reason: nil
            ))
        } catch {
            let failure = resolveFailure(error)
            let reason: String
            switch failure {
            case .notRun: reason = "reference image unavailable"
            case .ambiguousImage: reason = "ambiguous reference image"
            case .dimensionMismatch: reason = "reference dimensions do not match"
            case .comparisonFailed: reason = "reference comparison failed"
            default: reason = "unsupported reference image"
            }
            cases.append(BatchCaseOutput(
                status: failure == .notRun ? "NOT RUN" : "FAIL",
                rawID: rawID,
                caseID: matrixCase.caseID,
                width: nil,
                height: nil,
                metrics: nil,
                evaluation: nil,
                reason: reason
            ))
        }
    }
    let status: String
    if cases.allSatisfy({ $0.status == "PASS" }) {
        status = "PASS"
    } else if cases.contains(where: { $0.status == "NOT RUN" }) {
        status = "NOT RUN"
    } else {
        status = "FAIL"
    }
    printJSON(
        BatchOutput(
            status: status,
            mode: mode,
            cases: cases,
            thresholds: currentThresholdsOutput()
        ),
        status: status,
        reportURL: reportURL
    )
}

let requiredKeys = ["--mode", "--case", "--lr-neutral", "--lr-preset", "--lh-neutral", "--lh-preset"]
guard requiredKeys.allSatisfy({ parsed.values[$0] != nil }),
      let modeValue = parsed.values["--mode"],
      let mode = ReferenceComparisonMode(rawValue: modeValue),
      let caseID = parsed.values["--case"],
      let matrixCase = matrix.cases.first(where: { $0.caseID == caseID }) else {
    fail(.invalidArguments)
}
guard matrixCase.lrNeutralID == parsed.values["--lr-neutral"],
      matrixCase.lrPresetID == parsed.values["--lr-preset"],
      matrixCase.lhNeutralID == parsed.values["--lh-neutral"],
      matrixCase.lhPresetID == parsed.values["--lh-preset"] else {
    fail(.matrixMismatch, mode: mode, caseID: caseID, rawID: matrixCase.rawID)
}

do {
    let evaluated = try evaluate(mode: mode, matrixCase: matrixCase, in: imageDirectory)
    let status = evaluated.evaluation.isPassing ? "PASS" : "FAIL"
    printJSON(
        ComparisonOutput(
            status: status,
            mode: mode,
            caseID: caseID,
            rawID: matrixCase.rawID,
            width: evaluated.width,
            height: evaluated.height,
            metrics: metricsOutput(for: evaluated.result),
            thresholds: currentThresholdsOutput(),
            evaluation: evaluationOutput(for: evaluated.evaluation),
            reason: nil
        ),
        status: status,
        reportURL: reportURL
    )
} catch {
    fail(resolveFailure(error), mode: mode, caseID: caseID, rawID: matrixCase.rawID)
}
