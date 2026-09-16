import Foundation

struct LightroomXMPFixture: Sendable {
    let id: String
    let data: Data
}

enum LightroomXMPFixtureSupportError: Error, Equatable {
    case missingDirectory
    case emptyDirectory
    case unreadableFixture
}

enum LightroomXMPFixtureSupport {
    static let environmentKey = "LUMAHARBOR_LR_XMP_FIXTURE_DIR"

    static func load(environment: [String: String]) throws -> [LightroomXMPFixture] {
        guard let rawDirectory = environment[environmentKey], !rawDirectory.isEmpty else {
            throw LightroomXMPFixtureSupportError.missingDirectory
        }

        let directory = URL(fileURLWithPath: rawDirectory, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw LightroomXMPFixtureSupportError.missingDirectory
        }

        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            guard url.pathExtension.caseInsensitiveCompare("xmp") == .orderedSame else {
                return false
            }
            return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        .sorted { lhs, rhs in
            lhs.lastPathComponent.localizedCaseInsensitiveCompare(rhs.lastPathComponent) == .orderedAscending
        }

        guard !urls.isEmpty else {
            throw LightroomXMPFixtureSupportError.emptyDirectory
        }

        return try urls.enumerated().map { index, url in
            guard let data = try? Data(contentsOf: url), !data.isEmpty else {
                throw LightroomXMPFixtureSupportError.unreadableFixture
            }
            return LightroomXMPFixture(id: String(format: "fixture-%02d", index + 1), data: data)
        }
    }
}
