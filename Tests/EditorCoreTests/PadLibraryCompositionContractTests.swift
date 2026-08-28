import Foundation
import XCTest
@testable import EditorCore
import Localization
import PhotoLibraryCore
import RawProcessingCore

/// Task 6: the iPad app composes `LibraryBrowserSession` (Task 5) and
/// `PhotoDocumentEditor` (Task 4) from one shared `PhotoLibraryService` and
/// one shared `PhotoDocumentStore`, inside `PadAppServices`. That file lives
/// in a `.swiftpm` app package with no test target `swift test` can see or
/// run, so this file verifies the two things that actually matter about it
/// from here instead:
///
/// 1. `PadLibraryModel.swift` stays exactly what it claims to be -- a
///    stable name for `LibraryBrowserSession`, not a second, untested state
///    machine (source-parsed, since nothing else can catch that here).
/// 2. The composition itself is real: one `PhotoLibraryService` and one
///    `PhotoDocumentStore`, shared between a `LibraryBrowserSession` and a
///    `PhotoDocumentEditor`, actually lets a committed App copy show up
///    through the library browser -- the "no production caller yet" gap
///    both Task 4's and Task 5's own reports flagged as deferred to Task 6.
final class PadLibraryCompositionContractTests: XCTestCase {

    // MARK: - Source-parsing contract

    private static let repositoryRootURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // PadLibraryCompositionContractTests.swift
            .deletingLastPathComponent() // EditorCoreTests
            .deletingLastPathComponent() // Tests
    }()

    private static func padAppSourceURL(_ filename: String) -> URL {
        repositoryRootURL
            .appendingPathComponent("Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp", isDirectory: true)
            .appendingPathComponent(filename)
    }

    func testPadLibraryModelFileIsOnlyATypealiasNoSecondStateMachine() throws {
        let source = try String(contentsOf: Self.padAppSourceURL("PadLibraryModel.swift"), encoding: .utf8)

        XCTAssertTrue(
            source.contains("public typealias PadLibraryModel = LibraryBrowserSession"),
            "PadLibraryModel.swift must define PadLibraryModel as a typealias for LibraryBrowserSession"
        )
        for forbidden in ["class ", "struct ", "@Published", "ObservableObject", "func "] {
            XCTAssertFalse(
                source.contains(forbidden),
                "PadLibraryModel.swift must not contain '\(forbidden)' -- browsing logic belongs in " +
                    "EditorCore.LibraryBrowserSession, where EditorCoreTests can actually exercise it"
            )
        }
    }

    func testLumaHarborPadAppConstructsServicesInsideInitNeverInBody() throws {
        let source = try String(contentsOf: Self.padAppSourceURL("LumaHarborPadApp.swift"), encoding: .utf8)

        guard let initRange = source.range(of: "init() {"),
              let bodyRange = source.range(of: "var body: some Scene {") else {
            XCTFail("LumaHarborPadApp.swift must have both an init() and a body")
            return
        }
        XCTAssertTrue(initRange.lowerBound < bodyRange.lowerBound, "init() must come before body")

        let initSection = source[initRange.upperBound..<bodyRange.lowerBound]
        XCTAssertTrue(
            initSection.contains("PadAppServices("),
            "PadAppServices must be constructed inside init(), not lazily or from body"
        )

        let bodySection = source[bodyRange.upperBound...]
        XCTAssertFalse(
            bodySection.contains("PadAppServices("),
            "body must reuse the PadAppServices built in init(), never construct its own"
        )
    }

    // MARK: - Root-package compile/behavior contract

    /// Mirrors `PadAppServices.init` exactly (short of the two `Pad*Model`
    /// typealiases themselves, which only exist in the app package): one
    /// `PhotoLibraryService`, one `PhotoDocumentStore`, a
    /// `LibraryBrowserSession` built via `LibraryBrowserDependencies
    /// .live(service:)`, and a `PhotoDocumentEditor` built via the same
    /// full explicit `PhotoDocumentEditorDependencies` initializer
    /// `PadAppServices` uses -- proving that composition actually compiles
    /// and behaves correctly from the root package, where it's testable.
    @MainActor
    func testLibraryAndEditorShareOnePhotoLibraryServiceAndOnePhotoDocumentStore() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PadLibraryCompositionContractTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let locations = ApplicationSupportLocations(baseURL: rootURL.appendingPathComponent("LumaHarbor", isDirectory: true))
        try locations.createDirectories()

        let decoder = CoreImageRawDecoder()
        let renderService = ImageRenderService()
        let pipeline = AdjustmentPipeline()
        let previewRenderer = CoreImagePreviewRenderer(decoder: decoder, pipeline: pipeline, renderService: renderService)

        let libraryService = try PhotoLibraryService(locations: locations, decoder: decoder)
        let documentStore = PhotoDocumentStore(rootURL: rootURL.appendingPathComponent("PhotoDocuments", isDirectory: true))

        let editorDependencies = PhotoDocumentEditorDependencies(
            store: documentStore,
            decoder: decoder,
            previewScheduler: PreviewScheduler(renderer: previewRenderer),
            previewRenderer: previewRenderer,
            makeScope: { url in ScopedFolderAccess(url: url, startAccessing: true) },
            resolveScope: { data in
                let access = try ScopedFolderAccess(resolving: data)
                return ResolvedSecurityScope(resource: access, isStale: access.isStale)
            },
            makeBookmark: { url in try SecurityScopedBookmark.makeBookmarkData(for: url) }
        )

        let library = LibraryBrowserSession(dependencies: .live(service: libraryService))
        let editor = PhotoDocumentEditor(dependencies: editorDependencies)
        XCTAssertNil(editor.document)
        XCTAssertTrue(library.sources.isEmpty)

        // A committed App copy, created the same way the single-photo
        // "Open RAW…" flow does, must become visible through the library
        // browser once its projection is refreshed -- exactly the wiring
        // `PadAppServices.refreshAppStorageProjection()` performs.
        let sourceURL = rootURL.appendingPathComponent("fixture.ARW")
        try Data(repeating: 0x5A, count: 4_096).write(to: sourceURL)
        let creation = try await documentStore.importCopy(of: sourceURL, bookmarkData: nil)
        await documentStore.finalizeCreation(creation)

        let listing = try await documentStore.committedDocuments()
        XCTAssertTrue(listing.failures.isEmpty)
        try await libraryService.refreshAppStorageProjection(from: listing.documents)

        let appStoragePhotos = try await libraryService.photos(inLibrary: .appStorage)
        XCTAssertEqual(appStoragePhotos.count, 1)
        XCTAssertEqual(appStoragePhotos.first?.id, PhotoID(creation.document.id))
        XCTAssertEqual(appStoragePhotos.first?.libraryID, .appStorage)
        XCTAssertTrue(
            appStoragePhotos.first?.relativePath.hasSuffix(sourceURL.lastPathComponent) ?? false,
            "the projected asset's relativePath must be derived from the committed document's working file"
        )
    }
}
