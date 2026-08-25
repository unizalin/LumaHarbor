import Foundation
import XCTest
@testable import EditorCore
import PhotoLibraryCore
import RawProcessingCore

/// Codex review (Task 6, round 2): `EditorSession` used to forward
/// `error.errorDescription` verbatim into a modal alert. Several errors this
/// app throws embed a file's absolute path directly in that text —
/// `RawDecodingError.fileUnavailable` chief among them, since it is exactly
/// the error a missing/offline external RAW produces. These tests fix a
/// concrete fixture path into each such error and assert it never survives
/// into `SafeErrorPresentation`'s output, across every error family the app
/// defines.
final class SafeErrorPresentationTests: XCTestCase {
    /// A path shaped like a real one this app would actually see, so a
    /// regression that reintroduces `error.localizedDescription` somewhere
    /// would be caught, not accidentally dodged by using an unrealistic
    /// fixture.
    private let sensitivePath = "/Users/alice/Pictures/Import/DSC_secret_trip.ARW"

    private func assertNoLeak(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        let alert = SafeErrorPresentation.alert(title: "Title", for: error)
        for text in [alert.title, alert.message, alert.nextStep ?? ""] {
            XCTAssertFalse(text.contains("/Users/"), "leaked /Users/ in \"\(text)\"", file: file, line: line)
            XCTAssertFalse(text.contains("/Volumes/"), "leaked /Volumes/ in \"\(text)\"", file: file, line: line)
            XCTAssertFalse(text.contains("/private/var/"), "leaked /private/var/ in \"\(text)\"", file: file, line: line)
            XCTAssertFalse(text.contains(sensitivePath), "leaked the fixture path in \"\(text)\"", file: file, line: line)
            XCTAssertFalse(text.contains("secret_trip"), "leaked the filename in \"\(text)\"", file: file, line: line)
        }
    }

    func testRawDecodingErrorFileUnavailableNeverLeaksThePath() {
        assertNoLeak(RawDecodingError.fileUnavailable(path: sensitivePath))
    }

    func testRawDecodingErrorDecodeFailedNeverLeaksThePath() {
        assertNoLeak(RawDecodingError.decodeFailed(path: sensitivePath, reason: "at \(sensitivePath)"))
    }

    func testFingerprintErrorFileUnavailableNeverLeaksThePath() {
        assertNoLeak(FingerprintError.fileUnavailable(path: sensitivePath))
    }

    func testFingerprintErrorReadFailedNeverLeaksThePath() {
        assertNoLeak(FingerprintError.readFailed(path: sensitivePath, reason: "errno 2 at \(sensitivePath)"))
    }

    func testBookmarkErrorAccessDeniedNeverLeaksThePath() {
        assertNoLeak(BookmarkError.accessDenied(path: sensitivePath))
    }

    func testBookmarkErrorCouldNotCreateNeverLeaksThePath() {
        assertNoLeak(BookmarkError.couldNotCreate(path: sensitivePath, reason: "denied"))
    }

    func testSidecarErrorNotWritableNeverLeaksThePath() {
        assertNoLeak(SidecarError.notWritable(path: sensitivePath))
    }

    func testSidecarErrorLibraryUnavailableNeverLeaksThePath() {
        assertNoLeak(SidecarError.libraryUnavailable(path: sensitivePath))
    }

    func testAtomicWriteErrorDestinationNotWritableNeverLeaksThePath() {
        assertNoLeak(AtomicWriteError.destinationNotWritable(path: sensitivePath))
    }

    func testAtomicWriteErrorWriteFailedNeverLeaksThePath() {
        assertNoLeak(AtomicWriteError.writeFailed(path: sensitivePath, reason: "at \(sensitivePath)"))
    }

    func testLibraryErrorWrappingBookmarkErrorNeverLeaksThePath() {
        assertNoLeak(LibraryError.bookmark(.accessDenied(path: sensitivePath)))
    }

    func testLibraryErrorWrappingSidecarErrorNeverLeaksThePath() {
        assertNoLeak(LibraryError.sidecar(.notWritable(path: sensitivePath)))
    }

    func testLibraryErrorOfflineNeverLeaksThePath() {
        assertNoLeak(LibraryError.offline(path: sensitivePath))
    }

    func testUnknownNSErrorFallsBackToAGenericSafeMessage() {
        let error = NSError(
            domain: "test",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Couldn't open \(sensitivePath): permission denied."]
        )
        assertNoLeak(error)
        // Not a hardcoded-language comparison -- `L10n.t` resolves to
        // whatever the running system's locale is -- just that the mapper
        // never falls through to the raw NSError text itself.
        XCTAssertNotEqual(SafeErrorPresentation.message(for: error), error.localizedDescription)
        XCTAssertFalse(SafeErrorPresentation.message(for: error).isEmpty)
    }

    /// `nextStep` must stay non-nil (an actionable next step) for the
    /// families the app already relies on this for -- guarding against a
    /// regression that makes the alert safe by simply going silent.
    func testKnownFamiliesStillProvideANextStep() {
        XCTAssertNotNil(SafeErrorPresentation.nextStep(for: RawDecodingError.fileUnavailable(path: sensitivePath)))
        XCTAssertNotNil(SafeErrorPresentation.nextStep(for: SidecarError.notWritable(path: sensitivePath)))
        XCTAssertNotNil(SafeErrorPresentation.nextStep(for: LibraryError.sidecar(.notWritable(path: sensitivePath))))
        XCTAssertNotNil(SafeErrorPresentation.nextStep(for: PhotoDocumentError.copyVerificationFailed))
    }
}
