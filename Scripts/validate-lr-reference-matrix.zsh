#!/bin/zsh
set -euo pipefail

if (( $# < 1 || $# > 3 )); then
    print "usage: validate-lr-reference-matrix.zsh <matrix.json> [--images <directory>]" >&2
    exit 2
fi

matrix_path="$1"
image_directory=""
if (( $# == 3 )); then
    if [[ "$2" != "--images" ]]; then
        print "FAIL invalid image option" >&2
        exit 2
    fi
    image_directory="$3"
fi

if [[ ! -f "$matrix_path" ]]; then
    print "FAIL reference matrix is unavailable" >&2
    exit 1
fi

MATRIX_PATH="$matrix_path" IMAGE_DIRECTORY="$image_directory" swift - <<'SWIFT'
import Foundation

let environment = ProcessInfo.processInfo.environment
guard let matrixPath = environment["MATRIX_PATH"],
      let data = FileManager.default.contents(atPath: matrixPath),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      object["schemaVersion"] as? Int == 1,
      let cases = object["cases"] as? [[String: Any]],
      cases.count == 5 else {
    print("FAIL invalid reference matrix")
    exit(1)
}

let requiredKeys: Set<String> = [
    "fixtureID", "rawID", "lrNeutralID", "lrPresetID", "lhNeutralID", "lhPresetID",
    "profile", "processVersion", "colorSpace", "bitDepth", "width", "height"
]
let expectedFixtureIDs = Set(["fixture-a", "fixture-b", "fixture-c", "fixture-d", "fixture-e"])
var fixtureIDs = Set<String>()
var imageIDs = Set<String>()

for item in cases {
    guard Set(item.keys) == requiredKeys,
          let fixtureID = item["fixtureID"] as? String,
          expectedFixtureIDs.contains(fixtureID),
          fixtureIDs.insert(fixtureID).inserted else {
        print("FAIL invalid reference matrix case")
        exit(1)
    }
    for key in ["lrNeutralID", "lrPresetID", "lhNeutralID", "lhPresetID"] {
        guard let value = item[key] as? String,
              !value.isEmpty,
              !value.contains("/"),
              !value.contains("\\"),
              !value.contains("file://") else {
            print("FAIL invalid reference image ID")
            exit(1)
        }
        imageIDs.insert(value)
    }
}

guard fixtureIDs == expectedFixtureIDs else {
    print("FAIL reference matrix fixture IDs")
    exit(1)
}

if let imageDirectory = environment["IMAGE_DIRECTORY"], !imageDirectory.isEmpty {
    let directoryURL = URL(fileURLWithPath: imageDirectory, isDirectory: true)
    for imageID in imageIDs {
        let candidates = ["tiff", "tif", "png", "jpg", "jpeg"].map {
            directoryURL.appendingPathComponent("\(imageID).\($0)")
        }
        guard candidates.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            print("FAIL reference image is missing")
            exit(1)
        }
    }
}

print("PASS reference matrix schema=1 cases=5 images=20")
SWIFT
