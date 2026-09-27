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
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ImageReference {
    let rawID: String
    let role: String
    let imageID: String
}

struct ImageExpectation {
    let bitDepth: Int
    let width: Int
    let height: Int
    let colorSpace: String
}

func hasAlpha(_ alphaInfo: CGImageAlphaInfo) -> Bool {
    switch alphaInfo {
    case .none, .noneSkipFirst, .noneSkipLast:
        return false
    case .alphaOnly, .first, .last, .premultipliedFirst, .premultipliedLast:
        return true
    @unknown default:
        return true
    }
}

func validateImage(_ url: URL, against expectation: ImageExpectation) -> Bool {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let colorSpaceName = image.colorSpace?.name as String? else {
        return false
    }
    guard expectation.bitDepth == 16, expectation.width > 0, expectation.height > 0,
          expectation.colorSpace == "sRGB",
          let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let sourceType = CGImageSourceGetType(source),
          UTType(sourceType as String)?.conforms(to: .tiff) == true,
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let profileName = properties[kCGImagePropertyProfileName] as? String,
          profileName == "sRGB IEC61966-2.1",
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          image.width == expectation.width,
          image.height == expectation.height,
          image.bitsPerComponent == expectation.bitDepth,
          colorSpaceName == CGColorSpace.sRGB as String,
          hasAlpha(image.alphaInfo) else {
        return false
    }
    return true
}

func sha256Hex(of url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }

    var hasher = SHA256()
    while true {
        do {
            guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { break }
            hasher.update(data: data)
        } catch {
            return nil
        }
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

let environment = ProcessInfo.processInfo.environment
guard let matrixPath = environment["MATRIX_PATH"],
      let data = FileManager.default.contents(atPath: matrixPath),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      object["schemaVersion"] as? Int == 2,
      let cases = object["cases"] as? [[String: Any]],
      cases.count == 20 else {
    print("FAIL invalid reference matrix")
    exit(1)
}

let requiredKeys: Set<String> = [
    "caseID", "fixtureID", "rawID",
    "lrNeutralID", "lrPresetID", "lhNeutralID", "lhPresetID",
    "profile", "processVersion", "colorSpace", "bitDepth", "width", "height"
]
let expectedFixtureIDs = Set(["fixture-a", "fixture-b", "fixture-c", "fixture-d", "fixture-e"])
let expectedRawIDs = Set(["raw-a", "raw-b", "raw-c", "raw-d"])
let expectedCaseIDs = Set(expectedRawIDs.flatMap { rawID in
    expectedFixtureIDs.map { "\(rawID)--\($0)" }
})
var caseIDs = Set<String>()
var fixtureIDs = Set<String>()
var rawIDs = Set<String>()
var imageIDs = Set<String>()
var imageReferences: [ImageReference] = []
var imageExpectations: [String: ImageExpectation] = [:]

for item in cases {
    guard Set(item.keys) == requiredKeys,
          let caseID = item["caseID"] as? String,
          let fixtureID = item["fixtureID"] as? String,
          let rawID = item["rawID"] as? String,
          !rawID.isEmpty,
          !rawID.contains("/"),
          !rawID.contains("\\"),
          !rawID.contains("file://"),
          expectedCaseIDs.contains(caseID),
          expectedFixtureIDs.contains(fixtureID),
          expectedRawIDs.contains(rawID),
          caseID == "\(rawID)--\(fixtureID)",
          let bitDepth = item["bitDepth"] as? Int,
          let width = item["width"] as? Int,
          let height = item["height"] as? Int,
          let colorSpace = item["colorSpace"] as? String,
          bitDepth == 16,
          width > 0,
          height > 0,
          colorSpace == "sRGB",
          caseIDs.insert(caseID).inserted else {
        print("FAIL invalid reference matrix case")
        exit(1)
    }
    fixtureIDs.insert(fixtureID)
    rawIDs.insert(rawID)
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
        imageReferences.append(ImageReference(rawID: rawID, role: key, imageID: value))
        let expectation = ImageExpectation(
            bitDepth: bitDepth,
            width: width,
            height: height,
            colorSpace: colorSpace
        )
        if let existing = imageExpectations[value],
           existing.bitDepth != expectation.bitDepth
            || existing.width != expectation.width
            || existing.height != expectation.height
            || existing.colorSpace != expectation.colorSpace {
            print("FAIL inconsistent reference image metadata")
            exit(1)
        }
        imageExpectations[value] = expectation
    }
}

guard caseIDs == expectedCaseIDs,
      fixtureIDs == expectedFixtureIDs,
      rawIDs == expectedRawIDs else {
    print("FAIL reference matrix case coverage")
    exit(1)
}

if let imageDirectory = environment["IMAGE_DIRECTORY"], !imageDirectory.isEmpty {
    let directoryURL = URL(fileURLWithPath: imageDirectory, isDirectory: true)
    var resolvedImages: [String: URL] = [:]
    for imageID in imageIDs {
        let candidates = ["tiff", "tif", "png", "jpg", "jpeg"].map {
            directoryURL.appendingPathComponent("\(imageID).\($0)")
        }
        let matches = candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !matches.isEmpty else {
            print("FAIL reference image is missing")
            exit(1)
        }
        guard matches.count == 1 else {
            print("FAIL multiple reference image candidates")
            exit(1)
        }
        let resolved = matches[0]
        guard let expectation = imageExpectations[imageID], validateImage(resolved, against: expectation) else {
            print("FAIL reference image metadata")
            exit(1)
        }
        resolvedImages[imageID] = resolved
    }

    var referencesByHash: [String: [ImageReference]] = [:]
    var hashByImageID: [String: String] = [:]
    for reference in imageReferences {
        let hash: String
        if let cachedHash = hashByImageID[reference.imageID] {
            hash = cachedHash
        } else if let url = resolvedImages[reference.imageID],
                  let computedHash = sha256Hex(of: url) {
            hash = computedHash
            hashByImageID[reference.imageID] = computedHash
        } else {
            print("FAIL reference image cannot be read")
            exit(1)
        }
        referencesByHash[hash, default: []].append(reference)
    }

    for references in referencesByHash.values where references.count > 1 {
        guard let first = references.first else { continue }
        let isSharedNeutral = first.role == "lrNeutralID" || first.role == "lhNeutralID"
        let isExplicitSameReference = references.allSatisfy {
            $0.rawID == first.rawID
                && $0.role == first.role
                && $0.imageID == first.imageID
        }
        guard isSharedNeutral && isExplicitSameReference else {
            print("FAIL duplicate reference image content")
            exit(1)
        }
    }
}

print("PASS reference matrix schema=2 cases=20 references=80")
SWIFT
