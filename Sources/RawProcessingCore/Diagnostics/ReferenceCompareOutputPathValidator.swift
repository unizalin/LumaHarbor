import Foundation

public enum ReferenceCompareOutputPathError: Error, Equatable, Sendable {
    case reportIsInput
    case reportIsSymlink
    case reportIsDirectory
    case reportInsideReferenceDirectory
}

public enum ReferenceCompareOutputPathValidator {
    public static func validate(
        reportURL: URL,
        matrixURL: URL,
        referenceRootURL: URL
    ) throws {
        let report = reportURL.standardizedFileURL
        let resolvedReport = reportURL.resolvingSymlinksInPath().standardizedFileURL
        let resolvedMatrix = matrixURL.resolvingSymlinksInPath().standardizedFileURL
        let resolvedRoot = referenceRootURL.resolvingSymlinksInPath().standardizedFileURL

        if resolvedReport == resolvedMatrix {
            throw ReferenceCompareOutputPathError.reportIsInput
        }
        if FileManager.default.fileExists(atPath: report.path), isSymbolicLink(report) {
            throw ReferenceCompareOutputPathError.reportIsSymlink
        }
        if isDirectory(report) {
            throw ReferenceCompareOutputPathError.reportIsDirectory
        }
        if isWithin(resolvedReport, root: resolvedRoot) {
            throw ReferenceCompareOutputPathError.reportInsideReferenceDirectory
        }
    }

    private static func isWithin(_ candidate: URL, root: URL) -> Bool {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return candidate.path == root.path || candidate.path.hasPrefix(rootPath)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType else {
            return false
        }
        return type == .typeSymbolicLink
    }
}
