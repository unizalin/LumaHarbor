import Foundation
import XCTest

/// Shared scaffolding for the cross-module tests.
///
/// Integration tests here work against a real temporary directory, because the
/// behaviour under test (atomic replace, read-only volumes, relinking) is
/// exactly the behaviour a mocked file system would paper over.
class TemporaryDirectoryTestCase: XCTestCase {
    private(set) var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("LumaHarborTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let directory = temporaryDirectory {
            // A test may have made a directory read-only on purpose; restore
            // permissions so cleanup can't leak temp data across runs.
            restoreWritePermissions(at: directory)
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectory = nil
        try super.tearDownWithError()
    }

    func makeSubdirectory(_ name: String) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func writeFile(_ contents: Data, to url: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url)
        return url
    }

    func setPosixPermissions(_ permissions: Int, at url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: permissions)],
            ofItemAtPath: url.path
        )
    }

    private func restoreWritePermissions(at root: URL) {
        let fileManager = FileManager.default
        try? fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: root.path
        )
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return }
        for case let url as URL in enumerator {
            try? fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o755)],
                ofItemAtPath: url.path
            )
        }
    }
}
