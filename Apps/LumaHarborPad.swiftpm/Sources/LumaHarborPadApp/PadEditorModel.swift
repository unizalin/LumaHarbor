import EditorCore

/// The iPad app's document-editing model.
///
/// All document-lifecycle behavior — opening, restoring after a relaunch,
/// serializing overlapping operations, rolling back a document that failed
/// to open — lives in `EditorCore.PhotoDocumentEditor`, which
/// `EditorCoreTests` can compile and exercise directly with fake
/// dependencies. This `.swiftpm` application package has no test target
/// `swift test` can see or run, which is why that logic does not live here:
/// keeping it here would mean it could never actually be tested. This file
/// is kept only as a stable name for `LumaHarborPadApp`/`PadRootView`/
/// `PadEditorView` to reference; `PhotoDocumentEditor`'s own
/// `init(applicationSupportURL:)` supplies the real, platform-backed
/// dependencies (Files-importer security scopes, `UserDefaults`-backed
/// active-document persistence).
public typealias PadEditorModel = PhotoDocumentEditor
