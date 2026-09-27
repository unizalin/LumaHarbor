import Foundation
import RawProcessingCore
#if canImport(Darwin)
import Darwin
#endif

private let environment = ProcessInfo.processInfo.environment

if CommandLine.arguments.dropFirst().contains("--help") {
    print(ProfileCalibrationCommand.help)
    exit(0)
}

func fail(_ message: String) -> Never {
    // Keep errors aggregate-only. In particular, never interpolate an input
    // URL or basename into a command failure that may be attached to CI logs.
    FileHandle.standardError.write(Data("profile calibration failed: \(message)\n".utf8))
    exit(1)
}

func required(_ key: String) -> String {
    guard let value = environment[key], !value.isEmpty else {
        fail("missing required environment value")
        return ""
    }
    return value
}

func loadSamples(from key: String) -> [CameraProfileCalibrationSample] {
    let path = required(key)
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let samples = try? JSONDecoder().decode([CameraProfileCalibrationSample].self, from: data) else {
        fail("invalid paired sample input")
        return []
    }
    return samples
}

let training = loadSamples(from: "LUMAHARBOR_PROFILE_TRAINING_JSON")
let holdout = loadSamples(from: "LUMAHARBOR_PROFILE_HOLDOUT_JSON")
let result: CameraProfileCalibrationResult
do {
    result = try CameraProfileCalibrator.fit(
        id: required("LUMAHARBOR_PROFILE_ID"),
        cameraMatch: CameraMatch(
            make: required("LUMAHARBOR_PROFILE_CAMERA_MAKE"),
            model: required("LUMAHARBOR_PROFILE_CAMERA_MODEL")
        ),
        sourceProfileName: required("LUMAHARBOR_PROFILE_NAME"),
        training: training,
        holdout: holdout,
        provenance: required("LUMAHARBOR_PROFILE_PROVENANCE")
    )
} catch is CameraProfileCalibrationError {
    fail("calibration gate rejected the coefficient set")
} catch {
    fail("calibration could not produce a valid coefficient set")
}

do {
    print(try ProfileCalibrationCommand.sanitizedOutput(for: result))
} catch {
    fail("sanitized report could not be encoded")
}
