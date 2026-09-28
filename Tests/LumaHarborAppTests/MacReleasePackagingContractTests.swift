import Foundation
import XCTest

final class MacReleasePackagingContractTests: XCTestCase {
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func url(_ path: String) -> URL {
        Self.repositoryRoot.appendingPathComponent(path)
    }

    private func text(_ path: String) throws -> String {
        try String(contentsOf: url(path), encoding: .utf8)
    }

    func testBundleBuilderCopiesEveryRequiredSwiftPMResourceBundle() throws {
        let script = try text("Scripts/build-app-bundle.sh")

        XCTAssertTrue(script.contains("LumaHarbor_Localization.bundle"))
        XCTAssertTrue(script.contains("LumaHarbor_RawProcessingCore.bundle"))
        XCTAssertTrue(
            script.contains("cp -R \"${source_bundle}\" \"${APP_DIR}/Contents/Resources/\"")
        )
    }

    func testAppBundleBuildUsesStandardResourceLocationAndCustomLookup() throws {
        let buildScript = try text("Scripts/build-app-bundle.sh")
        let localization = try text("Sources/Localization/L10n.swift")
        let adjustmentPipeline = try text("Sources/RawProcessingCore/Pipeline/AdjustmentPipeline.swift")

        XCTAssertTrue(buildScript.contains("-DLUMAHARBOR_APP_BUNDLE"))
        for source in [localization, adjustmentPipeline] {
            XCTAssertTrue(source.contains("#if LUMAHARBOR_APP_BUNDLE"))
            XCTAssertTrue(source.contains("Bundle.main.resourceURL"))
        }
    }

    func testReleaseBinaryIsStrippedBeforeCodeSigning() throws {
        let script = try text("Scripts/build-app-bundle.sh")
        let stripRange = try XCTUnwrap(script.range(of: "strip -S"))
        let signingRange = try XCTUnwrap(script.range(of: "codesign --force"))

        XCTAssertLessThan(stripRange.lowerBound, signingRange.lowerBound)
    }

    func testMetalCompilerDoesNotEmbedPrivateSourcePaths() throws {
        let plugin = try text("Plugins/CompileMetalKernels/CompileMetalKernels.swift")

        XCTAssertTrue(plugin.contains("-fdebug-prefix-map"))
        XCTAssertTrue(plugin.contains("-fdebug-compilation-dir=."))
        XCTAssertTrue(plugin.contains("-frecord-sources=no"))
        XCTAssertTrue(plugin.contains("source_copy="))
        XCTAssertTrue(plugin.contains("cp \"$f\" \"$source_copy\""))
        XCTAssertTrue(plugin.contains("cd \\(shellQuote(intermediatesDirectory.string))"))
    }

    func testReleasePackagerUsesNeutralScratchPathAndScansAppAndArchive() throws {
        let buildScript = try text("Scripts/build-app-bundle.sh")
        let packageScript = try text("Scripts/package-mac-release.sh")

        XCTAssertTrue(buildScript.contains("LUMAHARBOR_SCRATCH_PATH"))
        XCTAssertTrue(buildScript.contains("--scratch-path"))
        XCTAssertTrue(packageScript.contains("LUMAHARBOR_SCRATCH_PATH"))
        XCTAssertTrue(packageScript.contains("LUMAHARBOR_RELEASE_SCRATCH_PARENT:-/private/tmp"))
        XCTAssertTrue(packageScript.contains("LumaHarborReleaseBuild.XXXXXX"))
        XCTAssertGreaterThanOrEqual(
            packageScript.components(separatedBy: "verify-release-privacy.sh").count - 1,
            2
        )
        XCTAssertTrue(packageScript.contains("ditto -x -k"))
    }

    func testReleasePackagerStagesArtifactsBeforeAtomicPublication() throws {
        let packageScript = try text("Scripts/package-mac-release.sh")

        XCTAssertTrue(packageScript.contains("STAGING_ARCHIVE_PATH"))
        XCTAssertTrue(packageScript.contains("STAGING_CHECKSUM_PATH"))
        XCTAssertTrue(packageScript.contains("publish_release_artifacts"))
        XCTAssertFalse(packageScript.contains(#"rm -f "${ARCHIVE_PATH}""#))
        XCTAssertFalse(packageScript.contains(#"tee "${CHECKSUM_PATH}""#))
    }

    func testChecksumFileDoesNotRecordBuilderDirectory() throws {
        let packageScript = try text("Scripts/package-mac-release.sh")

        XCTAssertTrue(packageScript.contains(#"shasum -a 256 "${STAGING_ARCHIVE_PATH}""#))
        XCTAssertTrue(packageScript.contains(#""${ARCHIVE_DIGEST}" "${ARCHIVE_NAME}""#))
        XCTAssertTrue(packageScript.contains(#"verify-release-privacy.sh "${STAGING_CHECKSUM_PATH}""#))
        XCTAssertFalse(packageScript.contains(#"shasum -a 256 "${ARCHIVE_PATH}""#))
    }

    func testPrivacyScannerFailsClosedForPrivateAbsolutePaths() throws {
        let scanner = url("Scripts/verify-release-privacy.sh")
        XCTAssertTrue(FileManager.default.fileExists(atPath: scanner.path))

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumaHarborReleasePrivacyTests-(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let cleanFile = root.appendingPathComponent("clean.txt")
        try Data("/private/tmp/LumaHarborReleaseBuild/resource.bundle".utf8).write(to: cleanFile)
        XCTAssertEqual(try runScanner(scanner, target: root), 0)

        let forbiddenPaths = [
            "/Users/private-builder/Projects/LumaHarbor",
            "/Volumes/Private Drive/LumaHarbor",
            "/home/private-builder/LumaHarbor",
        ]
        for path in forbiddenPaths {
            try Data(path.utf8).write(to: root.appendingPathComponent(UUID().uuidString))
            XCTAssertNotEqual(try runScanner(scanner, target: root), 0, "scanner accepted \(path)")
        }
    }

    func testReleaseArchiveNameUsesOnlySemanticVersion() throws {
        let packageScript = try text("Scripts/package-mac-release.sh")
        let legacyArchivePattern = "${APP_NAME}-${VERSION}" + "-${BUILD_NUMBER}.zip"

        XCTAssertTrue(
            packageScript.contains(
                #"ARCHIVE_NAME="$(release_archive_name "${APP_NAME}" "${VERSION}")""#
            )
        )
        XCTAssertFalse(packageScript.contains(legacyArchivePattern))
    }

    func testReleaseVersioningHelperRejectsExistingArtifacts() throws {
        let helper = url("Scripts/release-versioning.sh")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumaHarborReleaseVersioning-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let archive = root.appendingPathComponent("LumaHarbor-0.1.0.zip")
        let checksum = root.appendingPathComponent("LumaHarbor-0.1.0.zip.sha256")
        FileManager.default.createFile(atPath: archive.path, contents: Data())

        let result = try runBash(
            #"source "$1"; assert_release_artifacts_available "$2" "$3""#,
            arguments: [helper.path, archive.path, checksum.path]
        )
        XCTAssertEqual(result.status, 3)
        XCTAssertTrue(result.stderr.contains("already exists"))
    }

    func testReleaseVersioningHelperRejectsDanglingCanonicalSymlinks() throws {
        let helper = url("Scripts/release-versioning.sh")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumaHarborDanglingCanonical-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let archive = root.appendingPathComponent("LumaHarbor-0.1.0.zip")
        let checksum = root.appendingPathComponent("LumaHarbor-0.1.0.zip.sha256")
        let missing = root.appendingPathComponent("missing")

        for candidate in [archive, checksum] {
            try FileManager.default.createSymbolicLink(at: candidate, withDestinationURL: missing)
            let result = try runBash(
                #"source "$1"; assert_release_artifacts_available "$2" "$3""#,
                arguments: [helper.path, archive.path, checksum.path]
            )

            XCTAssertEqual(result.status, 3, "accepted dangling symlink at \(candidate.lastPathComponent)")
            XCTAssertTrue(result.stderr.contains("already exists"))
            try FileManager.default.removeItem(at: candidate)
        }
    }

    func testReleaseVersioningHelperRejectsLegacyArchiveAndChecksumArtifacts() throws {
        let helper = url("Scripts/release-versioning.sh")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumaHarborLegacyReleaseVersioning-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let archive = root.appendingPathComponent("LumaHarbor-0.1.0.zip")
        let checksum = root.appendingPathComponent("LumaHarbor-0.1.0.zip.sha256")
        let legacyArtifacts = [
            root.appendingPathComponent("LumaHarbor-0.1.0-3.zip"),
            root.appendingPathComponent("LumaHarbor-0.1.0-4.zip.sha256"),
        ]

        for legacyArtifact in legacyArtifacts {
            FileManager.default.createFile(atPath: legacyArtifact.path, contents: Data())
            let result = try runBash(
                #"source "$1"; assert_release_artifacts_available "$2" "$3""#,
                arguments: [helper.path, archive.path, checksum.path]
            )

            XCTAssertEqual(result.status, 3, "accepted \(legacyArtifact.lastPathComponent)")
            XCTAssertTrue(result.stderr.contains("already exists"))
            try FileManager.default.removeItem(at: legacyArtifact)
        }
    }

    func testReleaseVersioningHelperRejectsDanglingLegacySymlinks() throws {
        let helper = url("Scripts/release-versioning.sh")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumaHarborDanglingLegacy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let archive = root.appendingPathComponent("LumaHarbor-0.1.0.zip")
        let checksum = root.appendingPathComponent("LumaHarbor-0.1.0.zip.sha256")
        let missing = root.appendingPathComponent("missing")
        let legacyCandidates = [
            root.appendingPathComponent("LumaHarbor-0.1.0-3.zip"),
            root.appendingPathComponent("LumaHarbor-0.1.0-4.zip.sha256"),
        ]

        for candidate in legacyCandidates {
            try FileManager.default.createSymbolicLink(at: candidate, withDestinationURL: missing)
            let result = try runBash(
                #"source "$1"; assert_release_artifacts_available "$2" "$3""#,
                arguments: [helper.path, archive.path, checksum.path]
            )

            XCTAssertEqual(result.status, 3, "accepted dangling legacy symlink at \(candidate.lastPathComponent)")
            XCTAssertTrue(result.stderr.contains("already exists"))
            try FileManager.default.removeItem(at: candidate)
        }
    }

    func testAtomicPublisherDoesNotOverwriteArchiveInjectedAfterReservation() throws {
        let scenario = try runPublicationScenario(inject: "archive")

        XCTAssertEqual(scenario.result.status, 3)
        XCTAssertEqual(try Data(contentsOf: scenario.archive), Data("intruder-archive".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: scenario.checksum.path))
    }

    func testAtomicPublisherRollsBackOwnArchiveWhenChecksumWasInjectedAfterReservation() throws {
        let scenario = try runPublicationScenario(inject: "checksum")

        XCTAssertEqual(scenario.result.status, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scenario.archive.path))
        XCTAssertEqual(try Data(contentsOf: scenario.checksum), Data("intruder-checksum".utf8))
    }

    func testAtomicPublisherRejectsLegacyArchiveInjectedAfterReservation() throws {
        let scenario = try runPublicationScenario(inject: "legacy")

        XCTAssertEqual(scenario.result.status, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scenario.archive.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: scenario.checksum.path))
        XCTAssertEqual(try Data(contentsOf: scenario.legacy), Data("intruder-legacy".utf8))
    }

    func testAtomicPublisherPublishesStagedBytesAndReservationCleanupKeepsFinalArtifacts() throws {
        let scenario = try runPublicationScenario(inject: "none")

        XCTAssertEqual(scenario.result.status, 0)
        XCTAssertEqual(try Data(contentsOf: scenario.archive), Data("our-archive".utf8))
        XCTAssertEqual(try Data(contentsOf: scenario.checksum), Data("our-checksum".utf8))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: scenario.archive.appendingPathExtension("reservation").path
            )
        )
    }

    func testPostPublishLegacyCollisionRollsBackOnlyOwnedFinalArtifacts() throws {
        let helper = url("Scripts/release-versioning.sh")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumaHarborPostPublishCollision-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let archive = root.appendingPathComponent("LumaHarbor-0.1.0.zip")
        let checksum = root.appendingPathComponent("LumaHarbor-0.1.0.zip.sha256")
        let legacy = root.appendingPathComponent("LumaHarbor-0.1.0-3.zip")
        let reservation = root.appendingPathComponent("LumaHarbor-0.1.0.zip.reservation")
        let stagingArchive = reservation.appendingPathComponent("archive.zip")
        let stagingChecksum = reservation.appendingPathComponent("archive.zip.sha256")

        let result = try runBash(
            #"""
            source "$1"
            reserve_release_artifacts "$2" "$3" "$5" owner || exit $?
            printf 'our-archive' > "$6"
            printf 'our-checksum' > "$7"
            ln -h "$6" "$2" || exit $?
            ln -h "$7" "$3" || exit $?
            printf 'intruder-legacy' > "$4"
            finalize_release_artifact_publication "$6" "$7" "$2" "$3"
            status="$?"
            release_release_artifact_reservation "$5" owner || true
            exit "${status}"
            """#,
            arguments: [
                helper.path,
                archive.path,
                checksum.path,
                legacy.path,
                reservation.path,
                stagingArchive.path,
                stagingChecksum.path,
            ]
        )

        XCTAssertEqual(result.status, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: checksum.path))
        XCTAssertEqual(try Data(contentsOf: legacy), Data("intruder-legacy".utf8))
    }

    func testPostPublishRollbackNeverDeletesAReplacementWithDifferentInode() throws {
        let helper = url("Scripts/release-versioning.sh")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumaHarborPostPublishReplacement-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let archive = root.appendingPathComponent("LumaHarbor-0.1.0.zip")
        let checksum = root.appendingPathComponent("LumaHarbor-0.1.0.zip.sha256")
        let reservation = root.appendingPathComponent("LumaHarbor-0.1.0.zip.reservation")
        let stagingArchive = reservation.appendingPathComponent("archive.zip")
        let stagingChecksum = reservation.appendingPathComponent("archive.zip.sha256")

        let result = try runBash(
            #"""
            source "$1"
            reserve_release_artifacts "$2" "$3" "$4" owner || exit $?
            printf 'our-archive' > "$5"
            printf 'our-checksum' > "$6"
            ln -h "$5" "$2" || exit $?
            ln -h "$6" "$3" || exit $?
            rm -f "$2"
            printf 'intruder-archive' > "$2"
            finalize_release_artifact_publication "$5" "$6" "$2" "$3"
            status="$?"
            release_release_artifact_reservation "$4" owner || true
            exit "${status}"
            """#,
            arguments: [
                helper.path,
                archive.path,
                checksum.path,
                reservation.path,
                stagingArchive.path,
                stagingChecksum.path,
            ]
        )

        XCTAssertEqual(result.status, 3)
        XCTAssertEqual(try Data(contentsOf: archive), Data("intruder-archive".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: checksum.path))
    }

    func testReleaseVersioningHelperAllowsOnlyOneProcessToReserveAnArtifact() throws {
        let helper = url("Scripts/release-versioning.sh")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumaHarborReleaseReservation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let archive = root.appendingPathComponent("LumaHarbor-0.1.0.zip")
        let checksum = root.appendingPathComponent("LumaHarbor-0.1.0.zip.sha256")
        let reservation = root.appendingPathComponent("LumaHarbor-0.1.0.zip.reservation")
        let ready = root.appendingPathComponent("first-process-ready")

        let first = try startBash(
            #"""
            source "$1"
            reserve_release_artifacts "$2" "$3" "$4" "$5"
            status="$?"
            printf '%s\n' "${status}" > "$6"
            if [[ "${status}" -eq 0 ]]; then
                IFS= read -r _
                release_release_artifact_reservation "$4" "$5"
            fi
            exit "${status}"
            """#,
            arguments: [
                helper.path,
                archive.path,
                checksum.path,
                reservation.path,
                "first-owner",
                ready.path,
            ]
        )

        XCTAssertTrue(waitForFile(ready), "first process did not acquire its reservation")
        XCTAssertEqual(
            try String(contentsOf: ready, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            "0"
        )

        let second = try runBash(
            #"""
            source "$1"
            reserve_release_artifacts "$2" "$3" "$4" "$5"
            status="$?"
            release_release_artifact_reservation "$4" "$5"
            exit "${status}"
            """#,
            arguments: [
                helper.path,
                archive.path,
                checksum.path,
                reservation.path,
                "second-owner",
            ]
        )

        XCTAssertEqual(second.status, 3)
        XCTAssertTrue(second.stderr.contains("already exists"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: reservation.path))

        first.input.fileHandleForWriting.closeFile()
        first.process.waitUntilExit()
        XCTAssertEqual(first.process.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reservation.path))
    }

    func testReleaseVersioningHelperProducesVersionOnlyName() throws {
        let helper = url("Scripts/release-versioning.sh")
        let result = try runBash(
            #"source "$1"; release_archive_name LumaHarbor 0.1.0"#,
            arguments: [helper.path]
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "LumaHarbor-0.1.0.zip"
        )
    }

    private func runScanner(_ scanner: URL, target: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scanner.path, target.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private struct BashResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private struct RunningBash {
        let process: Process
        let input: Pipe
    }

    private struct PublicationScenario {
        let result: BashResult
        let archive: URL
        let checksum: URL
        let legacy: URL
    }

    private func runPublicationScenario(inject: String) throws -> PublicationScenario {
        let helper = url("Scripts/release-versioning.sh")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumaHarborAtomicPublication-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let archive = root.appendingPathComponent("LumaHarbor-0.1.0.zip")
        let checksum = root.appendingPathComponent("LumaHarbor-0.1.0.zip.sha256")
        let legacy = root.appendingPathComponent("LumaHarbor-0.1.0-3.zip")
        let reservation = root.appendingPathComponent("LumaHarbor-0.1.0.zip.reservation")
        let stagingArchive = reservation.appendingPathComponent("archive.zip")
        let stagingChecksum = reservation.appendingPathComponent("archive.zip.sha256")

        let result = try runBash(
            #"""
            source "$1"
            reserve_release_artifacts "$2" "$3" "$5" owner || exit $?
            printf 'our-archive' > "$6"
            printf 'our-checksum' > "$7"
            case "$8" in
                archive) printf 'intruder-archive' > "$2" ;;
                checksum) printf 'intruder-checksum' > "$3" ;;
                legacy) printf 'intruder-legacy' > "$4" ;;
            esac
            publish_release_artifacts "$6" "$7" "$2" "$3"
            status="$?"
            release_release_artifact_reservation "$5" owner || true
            exit "${status}"
            """#,
            arguments: [
                helper.path,
                archive.path,
                checksum.path,
                legacy.path,
                reservation.path,
                stagingArchive.path,
                stagingChecksum.path,
                inject,
            ]
        )

        return PublicationScenario(
            result: result,
            archive: archive,
            checksum: checksum,
            legacy: legacy
        )
    }

    private func runBash(_ command: String, arguments: [String]) throws -> BashResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command, "release-versioning-test"] + arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()

        return BashResult(
            status: process.terminationStatus,
            stdout: String(decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            stderr: String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    private func startBash(_ command: String, arguments: [String]) throws -> RunningBash {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command, "release-versioning-test"] + arguments

        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return RunningBash(process: process, input: input)
    }

    private func waitForFile(_ url: URL) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return false
    }
}
