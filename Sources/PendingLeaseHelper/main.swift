import Foundation
import PhotoLibraryCore

/// A tiny helper executable that exists only so
/// `PendingLeaseSubprocessTests` can prove `PendingLock` contention across
/// *real, separate processes* — not two `PhotoDocumentStore` instances
/// sharing one PID, which cannot actually demonstrate that a genuinely
/// different process's crash releases the lease. Never shipped as part of
/// the app; built only as a test-support product.
///
/// Usage: `PendingLeaseHelper <rootURL path> <appCopy|inPlace> <source file
/// path> <ready file path>`
///
/// Acquires a pending creation's lease exactly like a real
/// `PhotoDocumentEditor` mid-flight would (via `importCopy`/`openInPlace`,
/// never finalized), writes the new document's id to `readyFilePath` only
/// once that lease is actually held, then blocks — holding the lease for
/// as long as this process is alive. The parent test drives what happens
/// next: a line written to this process's stdin makes it exit(0)
/// gracefully; `SIGKILL` ends it without any cooperation from this code at
/// all, exactly like a real crash, and the kernel releases the `flock` on
/// its own.
@main
struct PendingLeaseHelper {
    static func main() async {
        let arguments = CommandLine.arguments
        guard arguments.count >= 5 else {
            FileHandle.standardError.write(Data(
                "usage: PendingLeaseHelper <rootURL> <appCopy|inPlace> <sourceFile> <readyFilePath>\n".utf8
            ))
            exit(64)
        }

        let rootURL = URL(fileURLWithPath: arguments[1])
        let mode = arguments[2]
        let sourceURL = URL(fileURLWithPath: arguments[3])
        let readyFileURL = URL(fileURLWithPath: arguments[4])

        let store = PhotoDocumentStore(rootURL: rootURL)
        let documentID: UUID
        do {
            switch mode {
            case "appCopy":
                documentID = try await store.importCopy(of: sourceURL, bookmarkData: nil).document.id
            case "inPlace":
                documentID = try await store.openInPlace(sourceURL, bookmarkData: nil).document.id
            default:
                FileHandle.standardError.write(Data("unknown mode: \(mode)\n".utf8))
                exit(64)
            }
        } catch {
            FileHandle.standardError.write(Data("failed to acquire lease: \(error)\n".utf8))
            exit(1)
        }

        // Written only after the lease is genuinely held -- the parent
        // polls for this file rather than sleeping a guessed duration, so
        // it never observes "ready" before the lease actually exists.
        do {
            try Data(documentID.uuidString.utf8).write(to: readyFileURL)
        } catch {
            FileHandle.standardError.write(Data("failed to write ready file: \(error)\n".utf8))
            exit(1)
        }

        // Blocks until the parent either writes a line to stdin (graceful
        // exit below) or sends SIGKILL (no cooperation possible or
        // needed -- the kernel tears the process, and the lease with it,
        // down on its own).
        _ = readLine()
        exit(0)
    }
}
