import EditorCore

/// The iPad app's multi-source library-browsing model.
///
/// All browsing behavior — restoring sources, paging, selection, search
/// debounce, query-generation staleness, restoration anchoring, per-source
/// scan progress — lives in `EditorCore.LibraryBrowserSession`, which
/// `EditorCoreTests` can compile and exercise directly with fake
/// dependencies (`Tests/EditorCoreTests/LibraryBrowserSessionTests.swift`).
/// This `.swiftpm` application package has no test target `swift test` can
/// see or run, which is why that logic does not live here — exactly the
/// same reasoning `PadEditorModel.swift` already documents for the editor
/// side. This file is kept only as a stable name for
/// `PadAppServices`/`PadRootView`/`PadLibraryView`/`PadLibrarySidebar` to
/// reference; `LibraryBrowserDependencies.live(service:)` supplies the
/// real, platform-backed dependencies.
public typealias PadLibraryModel = LibraryBrowserSession
