import XCTest
@testable import RawProcessingCore

/// Roadmap Phase 5 Task 5.2: "Add collision policy tests: increment, ask,
/// skip" -- design spec §6.11's "同名檔處理:遞增流水號、詢問、或跳過".
///
/// `.ask` has no interactive prompt in this build -- there is no UI seam in
/// a sequential batch export to pause mid-run and wait for a per-file
/// decision. Per the roadmap's own instruction not to fake support for it,
/// `.ask` must resolve to a distinct, unmistakable `.unsupported` outcome,
/// never silently fall back to `.increment` or `.skip`.
final class ExportCollisionPolicyTests: XCTestCase {
    private let directory = URL(fileURLWithPath: "/tmp/exports", isDirectory: true)

    // MARK: - increment

    func testIncrementResolvesThePlainNameWhenNothingExists() throws {
        let resolution = UniqueFilenameResolver.resolve(
            baseName: "DSC0001",
            fileExtension: "jpg",
            in: directory,
            policy: .increment,
            exists: { _ in false }
        )
        guard case .proceed(let url) = resolution else {
            return XCTFail("expected .proceed, got \(resolution)")
        }
        XCTAssertEqual(url.lastPathComponent, "DSC0001.jpg")
    }

    func testIncrementAddsASerialSuffixOnCollision() throws {
        let taken: Set<String> = ["DSC0001.jpg"]
        let resolution = UniqueFilenameResolver.resolve(
            baseName: "DSC0001",
            fileExtension: "jpg",
            in: directory,
            policy: .increment,
            exists: { taken.contains($0.lastPathComponent) }
        )
        guard case .proceed(let url) = resolution else {
            return XCTFail("expected .proceed, got \(resolution)")
        }
        XCTAssertEqual(url.lastPathComponent, "DSC0001-1.jpg")
    }

    func testIncrementReportsExhaustionDistinctlyFromEveryOtherOutcome() {
        let resolution = UniqueFilenameResolver.resolve(
            baseName: "DSC0001",
            fileExtension: "jpg",
            in: directory,
            policy: .increment,
            maximumAttempts: 3,
            exists: { _ in true }
        )
        XCTAssertEqual(resolution, .incrementExhausted)
    }

    // MARK: - skip

    func testSkipProceedsWithThePlainNameWhenNothingExists() throws {
        let resolution = UniqueFilenameResolver.resolve(
            baseName: "DSC0001",
            fileExtension: "jpg",
            in: directory,
            policy: .skip,
            exists: { _ in false }
        )
        guard case .proceed(let url) = resolution else {
            return XCTFail("expected .proceed, got \(resolution)")
        }
        XCTAssertEqual(url.lastPathComponent, "DSC0001.jpg")
    }

    func testSkipNeverIncrementsAndReportsSkipOnCollision() {
        let resolution = UniqueFilenameResolver.resolve(
            baseName: "DSC0001",
            fileExtension: "jpg",
            in: directory,
            policy: .skip,
            exists: { $0.lastPathComponent == "DSC0001.jpg" }
        )
        XCTAssertEqual(resolution, .skip, "skip must never fall back to incrementing a suffix")
    }

    // MARK: - ask (not supported)

    func testAskAlwaysReportsUnsupportedRegardlessOfWhetherTheFileExists() {
        XCTAssertEqual(
            UniqueFilenameResolver.resolve(baseName: "DSC0001", fileExtension: "jpg", in: directory, policy: .ask, exists: { _ in false }),
            .unsupportedAsk
        )
        XCTAssertEqual(
            UniqueFilenameResolver.resolve(baseName: "DSC0001", fileExtension: "jpg", in: directory, policy: .ask, exists: { _ in true }),
            .unsupportedAsk
        )
    }

    func testAskNeverProceedsOrSkips() {
        let resolution = UniqueFilenameResolver.resolve(
            baseName: "DSC0001",
            fileExtension: "jpg",
            in: directory,
            policy: .ask,
            exists: { _ in false }
        )
        if case .proceed = resolution {
            XCTFail("`.ask` must never silently behave like `.increment` -- it has no prompt implemented yet")
        }
        if case .skip = resolution {
            XCTFail("`.ask` must never silently behave like `.skip` -- it has no prompt implemented yet")
        }
    }

    // MARK: - Coverage

    func testEveryPolicyHasAVisibleDisplayName() {
        for policy in ExportCollisionPolicy.allCases {
            XCTAssertFalse(policy.displayName.isEmpty, "\(policy) has no display name")
        }
    }

    func testDefaultPolicyIsIncrementPreservingExistingBehaviour() {
        XCTAssertEqual(ExportCollisionPolicy.increment, ExportCollisionPolicy.default)
    }
}
