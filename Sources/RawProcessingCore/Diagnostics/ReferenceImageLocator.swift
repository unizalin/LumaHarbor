import Foundation

public enum ReferenceImageLocatorError: Error, Equatable, Hashable, Sendable {
    case notFound
    case ambiguous
}

public enum ReferenceImageLocator {
    public static let supportedExtensions = ["tiff", "tif", "png", "jpg", "jpeg"]

    public static func resolve(identifier: String, in directory: URL) throws -> URL {
        let matches = supportedExtensions
            .map { directory.appendingPathComponent("\(identifier).\($0)") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }

        guard !matches.isEmpty else {
            throw ReferenceImageLocatorError.notFound
        }
        guard matches.count == 1 else {
            throw ReferenceImageLocatorError.ambiguous
        }
        return matches[0]
    }
}
