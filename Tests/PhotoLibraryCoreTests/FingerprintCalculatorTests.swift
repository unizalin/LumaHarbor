import XCTest
@testable import PhotoLibraryCore

/// Spec §8.1: size plus SHA-256 over the first and last 1 MiB, whole file under
/// 2 MiB. The exact byte layout is on-disk format — a change here invalidates
/// every stored fingerprint, so these tests exist to make that deliberate.
final class FingerprintCalculatorTests: TemporaryDirectoryTestCase {
    func testSmallFileHashesItsWholeContent() throws {
        let url = try writeFile(
            Data("hello lumaharbor".utf8),
            at: temporaryDirectory.appendingPathComponent("small.ARW")
        )
        let fromDisk = try FingerprintCalculator.fingerprint(forFileAt: url)
        let fromMemory = FingerprintCalculator.fingerprint(
            forData: Data("hello lumaharbor".utf8)
        )
        XCTAssertEqual(fromDisk, fromMemory)
        XCTAssertEqual(fromDisk.fileSize, 16)
        XCTAssertEqual(fromDisk.edgeDigest.count, 64, "SHA-256 hex is 64 characters")
    }

    func testDigestIsLowercaseHex() throws {
        let fingerprint = FingerprintCalculator.fingerprint(forData: Data("x".utf8))
        XCTAssertTrue(
            fingerprint.edgeDigest.allSatisfy { $0.isHexDigit && !$0.isUppercase }
        )
    }

    func testIdenticalContentProducesIdenticalFingerprints() throws {
        let first = try writeFile(
            Data(repeating: 0x42, count: 4_096),
            at: temporaryDirectory.appendingPathComponent("a.ARW")
        )
        let second = try writeFile(
            Data(repeating: 0x42, count: 4_096),
            at: temporaryDirectory.appendingPathComponent("b/c.ARW")
        )
        let firstFingerprint = try FingerprintCalculator.fingerprint(forFileAt: first)
        let secondFingerprint = try FingerprintCalculator.fingerprint(forFileAt: second)
        XCTAssertEqual(
            firstFingerprint,
            secondFingerprint,
            "Fingerprints must not depend on the path — relinking relies on it"
        )
    }

    func testDifferentContentProducesDifferentFingerprints() {
        XCTAssertNotEqual(
            FingerprintCalculator.fingerprint(forData: Data(repeating: 0x01, count: 512)),
            FingerprintCalculator.fingerprint(forData: Data(repeating: 0x02, count: 512))
        )
    }

    func testSizeIsPartOfTheDigestNotJustTheStruct() {
        // Two files sharing edge bytes but differing in length must not collide.
        let short = FingerprintCalculator.fingerprint(forData: Data(repeating: 0x01, count: 512))
        let long = FingerprintCalculator.fingerprint(forData: Data(repeating: 0x01, count: 513))
        XCTAssertNotEqual(short.edgeDigest, long.edgeDigest)
    }

    func testLargeFileOnlyHashesItsEdges() throws {
        // Three MiB: head and tail are hashed, the middle is not. Changing only
        // the middle must therefore produce the same digest — that is the
        // documented trade-off, and asserting it stops the threshold drifting.
        let size = 3 * 1_024 * 1_024
        var original = Data(repeating: 0xAA, count: size)
        var mutatedMiddle = original
        mutatedMiddle[size / 2] = 0x55

        XCTAssertEqual(
            FingerprintCalculator.fingerprint(forData: original),
            FingerprintCalculator.fingerprint(forData: mutatedMiddle)
        )

        // Changing an edge byte must change it.
        original[0] = 0x55
        XCTAssertNotEqual(
            FingerprintCalculator.fingerprint(forData: original),
            FingerprintCalculator.fingerprint(forData: mutatedMiddle)
        )
    }

    func testLargeFileFromDiskMatchesTheInMemoryAlgorithm() throws {
        let size = 3 * 1_024 * 1_024
        var data = Data(repeating: 0x11, count: size)
        data[0] = 0x01
        data[size - 1] = 0x02

        let url = try writeFile(data, at: temporaryDirectory.appendingPathComponent("big.ARW"))
        let fromDisk = try FingerprintCalculator.fingerprint(forFileAt: url)
        XCTAssertEqual(fromDisk, FingerprintCalculator.fingerprint(forData: data))
    }

    func testThresholdBoundaryIsStable() throws {
        // Exactly 2 MiB is hashed whole; one byte more switches to edges.
        let threshold = Int(FingerprintCalculator.wholeFileThreshold)
        let atThreshold = Data(repeating: 0x7F, count: threshold)
        let url = try writeFile(
            atThreshold, at: temporaryDirectory.appendingPathComponent("threshold.ARW")
        )
        let fromDisk = try FingerprintCalculator.fingerprint(forFileAt: url)
        XCTAssertEqual(fromDisk, FingerprintCalculator.fingerprint(forData: atThreshold))
    }

    func testEmptyFileIsHandled() throws {
        let url = try writeFile(Data(), at: temporaryDirectory.appendingPathComponent("empty.ARW"))
        let fingerprint = try FingerprintCalculator.fingerprint(forFileAt: url)
        XCTAssertEqual(fingerprint.fileSize, 0)
        XCTAssertEqual(fingerprint.edgeDigest.count, 64)
    }

    func testMissingFileThrowsUnavailable() {
        let missing = temporaryDirectory.appendingPathComponent("gone.ARW")
        XCTAssertThrowsError(try FingerprintCalculator.fingerprint(forFileAt: missing)) { error in
            guard case FingerprintError.fileUnavailable = error else {
                return XCTFail("Expected .fileUnavailable, got \(error)")
            }
        }
    }

    func testFingerprintErrorsTellTheUserWhatToDo() {
        let error = FingerprintError.fileUnavailable(path: "/Volumes/SSD/a.ARW")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertNotNil(error.recoverySuggestion)
    }
}
