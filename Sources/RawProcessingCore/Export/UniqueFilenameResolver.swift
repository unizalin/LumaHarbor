import Foundation

/// Picks a non-colliding output filename.
///
/// Spec §6.3: an existing file at the destination gets a serial suffix; silent
/// overwriting is forbidden. Pure and injectable so the collision behaviour is
/// testable without creating thousands of files.
public enum UniqueFilenameResolver {
    public static let maximumAttempts = 10_000

    /// Returns `base.ext`, or `base-1.ext`, `base-2.ext`, … for the first name
    /// `exists` reports free. `nil` when the limit is reached.
    public static func resolve(
        baseName: String,
        fileExtension: String,
        in directory: URL,
        maximumAttempts: Int = maximumAttempts,
        exists: (URL) -> Bool
    ) -> URL? {
        let safeBase = sanitize(baseName)
        let candidate = directory.appendingPathComponent(safeBase)
            .appendingPathExtension(fileExtension)
        if !exists(candidate) { return candidate }

        for index in 1...max(1, maximumAttempts) {
            let next = directory.appendingPathComponent("\(safeBase)-\(index)")
                .appendingPathExtension(fileExtension)
            if !exists(next) { return next }
        }
        return nil
    }

    public static func resolve(
        baseName: String,
        fileExtension: String,
        in directory: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        resolve(baseName: baseName, fileExtension: fileExtension, in: directory) { url in
            fileManager.fileExists(atPath: url.path)
        }
    }

    /// Strips path separators and NUL so a filename derived from a RAW's name
    /// can never escape the chosen directory.
    static func sanitize(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled" : cleaned
    }
}
