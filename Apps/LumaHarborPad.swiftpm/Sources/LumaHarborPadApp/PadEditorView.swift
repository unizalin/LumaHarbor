import AdjustmentUI
import EditorCore
import Localization
import Photos
import RawProcessingCore
import SwiftUI
import UniformTypeIdentifiers

/// The adaptive editing surface (Task 7): the same canvas and the same ten
/// basic sliders as Task 6, but the *container* the sliders live in adapts
/// to the available size and to an explicit work/focus toggle —
/// `PadEditorLayoutPolicy` decides trailing dock vs. bottom drawer purely
/// from width/height, `PadBottomDrawerPolicy` decides whether the drawer
/// sheet should actually be presented, and `workspaceState.workspaceMode`
/// decides work vs. focus.
///
/// `editor` — and therefore the open photo, its adjustments, and its undo
/// stack — is the same `EditorSession` instance across every layout this
/// view ever renders; resizing, rotating, or toggling work/focus only ever
/// changes which container the same controls render inside, never what
/// document is open or what state it holds.
///
/// `workspaceState` (mode, canvas zoom, floating-panel offset) is
/// deliberately scoped to *one specific document*, not to this view's own
/// lifetime: `PadEditorView` is not recreated when `model.document` changes
/// from one document to another (`PadRootView` keeps showing the same
/// `PadEditorView` the whole time `model.document != nil`), so this view
/// explicitly resets that state via `PadDocumentScopedWorkspacePolicy`
/// whenever the open document's id actually changes — see `body`'s
/// `.onChange(of: model.document?.id)`.
struct PadEditorView: View {
    @ObservedObject var model: PadEditorModel
    @ObservedObject private var editor: EditorSession
    let exporter: PhotoExporter

    /// Work/focus mode, canvas zoom, and floating-panel position — see the
    /// type's own documentation for why these three travel together and
    /// reset together. View-local `@State`: survives every work/focus
    /// toggle and every resize/rotation for the *same* document, but is
    /// explicitly reset (not merely "happens to survive") when the open
    /// document's id changes underneath this same view instance.
    @State private var workspaceState = PadDocumentScopedWorkspaceState.initial

    /// Whether the bottom drawer sheet is currently presented — a real,
    /// toggleable binding driven by `PadBottomDrawerPolicy`, never a
    /// `.sheet(isPresented: .constant(true))`. See `updateDrawerPresentation`.
    @State private var isDrawerPresented = false

    /// The most recent size `GeometryReader` reported. Kept as `@State`
    /// (rather than threaded through every computed property that needs
    /// it) so gesture callbacks — which run outside `body`'s own
    /// evaluation — can still read "what's the available size right now."
    @State private var availableSize: CGSize = .zero

    /// The floating panel's own measured size, captured via
    /// `FloatingPanelSizeKey` below. Used only for clamping; defaults to a
    /// reasonable estimate (matching the panel's fixed 320pt width) so a
    /// re-clamp before the very first real measurement still behaves
    /// sanely rather than clamping against a degenerate zero-size box.
    @State private var floatingPanelMeasuredSize = CGSize(width: 320, height: 400)
    @State private var exportedURL: URL?
    @State private var isExporting = false
    @State private var isSavingToPhotos = false
    /// Drives the explicit "Save to Files" `fileExporter` flow (spec
    /// §5.5.1), alongside the existing ShareLink/Photos destinations --
    /// never a second export path, only a second *destination picker* over
    /// the same already-exported file at `exportedURL`.
    @State private var isPresentingFileExporter = false

    @GestureState private var floatingPanelDragTranslation: CGSize = .zero
    @GestureState private var canvasMagnification: CGFloat = 1

    private static let minimumCanvasScale: CGFloat = 1
    private static let maximumCanvasScale: CGFloat = 5
    /// How much of the floating panel must stay reachable within the
    /// available area at all times — see `PadFloatingPanelLayout`.
    private static let floatingPanelMinimumVisibleEdge: CGFloat = 44
    private static let floatingPanelDefaultOrigin = CGPoint(x: 24, y: 24)

    init(model: PadEditorModel, exporter: PhotoExporter) {
        self.model = model
        self.editor = model.editor
        self.exporter = exporter
    }

    var body: some View {
        GeometryReader { proxy in
            workspaceContent
                .sheet(isPresented: $isDrawerPresented) {
                    bottomDrawerPanel
                        .presentationDetents([.height(220), .medium, .large])
                        .presentationDragIndicator(.visible)
                        // A drawer that could be swiped away entirely would
                        // leave the user with no way back to the controls
                        // short of resizing/rotating the window again —
                        // resizing between the three detents above is
                        // still fully interactive.
                        .interactiveDismissDisabled(true)
                        .presentationBackgroundInteraction(.enabled)
                }
                .onAppear {
                    availableSize = proxy.size
                    updateDrawerPresentation()
                }
                .onChange(of: proxy.size) { _, newSize in
                    availableSize = newSize
                    updateDrawerPresentation()
                    reclampFloatingPanelOffset()
                }
                .onChange(of: workspaceState.workspaceMode) { _, _ in
                    updateDrawerPresentation()
                }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.t("Close")) {
                    Task { await model.closeCurrentDocument() }
                }
                .disabled(model.isPreparingDocument)
            }
            ToolbarItem(placement: .primaryAction) {
                workspaceModeToggle
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    exportFullResolution()
                } label: {
                    if isExporting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label(L10n.t("Export"), systemImage: "square.and.arrow.up")
                    }
                }
                .disabled(isExporting || model.document == nil)
                .accessibilityLabel(Text(L10n.t("Export")))

                if let exportedURL {
                    ShareLink(item: exportedURL) {
                        Label(L10n.t("Share"), systemImage: "square.and.arrow.up.on.square")
                    }
                    .accessibilityLabel(Text(L10n.t("Share exported photo")))

                    Button {
                        saveToPhotos(exportedURL)
                    } label: {
                        if isSavingToPhotos {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label(L10n.t("Save to Photos"), systemImage: "photo.badge.plus")
                        }
                    }
                    .disabled(isSavingToPhotos)

                    Button {
                        isPresentingFileExporter = true
                    } label: {
                        Label(L10n.t("Save to Files"), systemImage: "folder")
                    }
                    .accessibilityLabel(Text(L10n.t("Save to Files")))
                }
            }
        }
        .alert(item: $editor.alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alertBody(alert)),
                dismissButton: .default(Text(L10n.t("OK")))
            )
        }
        // Spec §5.5.1/§5.5.2: a third, explicit destination over the exact
        // same full-resolution export `exportFullResolution()` already
        // produced -- never a second encode of the photo, just a
        // `FileDocument` wrapper (`ExportedPhotoFileDocument`) around the
        // bytes already on disk at `exportedURL`.
        .fileExporter(
            isPresented: $isPresentingFileExporter,
            document: exportedURL.map { ExportedPhotoFileDocument(fileURL: $0) },
            contentType: .jpeg,
            defaultFilename: exportedURL?.deletingPathExtension().lastPathComponent
        ) { result in
            switch result {
            case .success:
                break
            case .failure(let error):
                // Spec §5.5.3/§5.5.4: the user dismissing the picker is
                // `cancelled`, never shown as a failure alert.
                guard (error as? CocoaError)?.code != .userCancelled else { return }
                model.alert = EditorAlert(
                    title: L10n.t("Couldn't save to Files"),
                    message: error.localizedDescription,
                    nextStep: L10n.t("Try again.")
                )
            }
        }
        // The open document's identity, not this view's own lifetime, is
        // what scopes `workspaceState` — see the type's documentation.
        .onChange(of: model.document?.id) { oldValue, newValue in
            workspaceState = PadDocumentScopedWorkspacePolicy.resettingIfNeeded(
                workspaceState, previousDocumentID: oldValue, currentDocumentID: newValue
            )
        }
    }

    // MARK: - Drawer presentation

    /// The single place `isDrawerPresented` is ever written — always
    /// derived from `PadBottomDrawerPolicy`, from the two facts it needs
    /// (current mode, current inspector presentation for `availableSize`).
    /// Called whenever either of those can have changed: mode toggling,
    /// and `availableSize` changing (resize/rotation/Split View).
    private func updateDrawerPresentation() {
        let inspectorPresentation = PadEditorLayoutPolicy.presentation(forWidth: availableSize.width, height: availableSize.height)
        let target = PadBottomDrawerPolicy.presentation(mode: workspaceState.workspaceMode, inspectorPresentation: inspectorPresentation) == .presented
        if isDrawerPresented != target {
            isDrawerPresented = target
        }
    }

    // MARK: - Work / focus toggle

    private var workspaceModeToggle: some View {
        // Switching `workspaceState.workspaceMode` is the only thing this
        // button does directly — no `editor` call of any kind, so it can
        // never create an undo entry, touch adjustments, or open/close
        // anything. `updateDrawerPresentation()` (triggered by the
        // `.onChange` below, not called here) only ever touches
        // `isDrawerPresented`, equally inert from `editor`'s perspective.
        Button {
            workspaceState.workspaceMode = (workspaceState.workspaceMode == .work) ? .focus : .work
        } label: {
            switch workspaceState.workspaceMode {
            case .work:
                Label(L10n.t("Focus Mode"), systemImage: "rectangle.inset.filled")
            case .focus:
                Label(L10n.t("Work Mode"), systemImage: "rectangle.split.2x1")
            }
        }
        // Explicit, not left to `Label`'s own inference — a toolbar can
        // render this icon-only depending on available space, and an
        // icon-only control must still have a real accessibility label.
        .accessibilityLabel(Text(workspaceState.workspaceMode == .work ? L10n.t("Focus Mode") : L10n.t("Work Mode")))
    }

    // MARK: - Layout selection

    @ViewBuilder
    private var workspaceContent: some View {
        switch workspaceState.workspaceMode {
        case .work:
            workLayout
        case .focus:
            focusLayout
        }
    }

    /// The bottom drawer's own presentation is handled entirely by the
    /// `.sheet(isPresented: $isDrawerPresented)` attached once, up in
    /// `body` — never nested inside this `switch`, so its view identity
    /// stays stable across every presentation/mode change instead of
    /// being torn down and rebuilt (which is what made the drawer
    /// unreliable to close and reopen before). This only decides the
    /// *dock* layout; `.bottomDrawer` just needs the canvas alone.
    @ViewBuilder
    private var workLayout: some View {
        let presentation = PadEditorLayoutPolicy.presentation(forWidth: availableSize.width, height: availableSize.height)
        switch presentation {
        case .trailingDock:
            HStack(spacing: 0) {
                canvas
                Divider()
                trailingDockPanel
            }
        case .bottomDrawer:
            canvas
        }
    }

    private var focusLayout: some View {
        ZStack(alignment: .topLeading) {
            canvas
            floatingPanel
                .background(floatingPanelSizeReader)
                .offset(
                    x: Self.floatingPanelDefaultOrigin.x + workspaceState.floatingPanelOffset.width + floatingPanelDragTranslation.width,
                    y: Self.floatingPanelDefaultOrigin.y + workspaceState.floatingPanelOffset.height + floatingPanelDragTranslation.height
                )
        }
    }

    // MARK: - Canvas (shared by every layout)

    @ViewBuilder
    private var canvas: some View {
        ZStack {
            Color.black
            if let image = editor.displayedImage {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .padding()
                    .scaleEffect(workspaceState.canvasScale * canvasMagnification)
                    .gesture(
                        MagnificationGesture()
                            .updating($canvasMagnification) { value, state, _ in
                                state = value
                            }
                            .onEnded { value in
                                let proposed = workspaceState.canvasScale * value
                                workspaceState.canvasScale = min(max(proposed, Self.minimumCanvasScale), Self.maximumCanvasScale)
                            }
                    )
            } else if editor.decodeFailed {
                ContentUnavailableView(
                    L10n.t("Couldn't show this photo"),
                    systemImage: "exclamationmark.triangle"
                )
            } else {
                ProgressView(L10n.t("Decoding RAW…"))
                    .tint(.white)
                    .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    // MARK: - Full-resolution export

    private func exportFullResolution() {
        guard let document = model.document else { return }
        isExporting = true

        Task {
            do {
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("LumaHarbor-Exports", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                let request = ExportRequest(
                    sourceURL: document.workingURL,
                    adjustments: editor.adjustments,
                    destinationDirectory: directory,
                    baseFilename: document.workingURL.deletingPathExtension().lastPathComponent,
                    format: .jpeg,
                    quality: 1,
                    exifRetentionPolicy: .preserveAll
                )
                let outcome = try await exporter.export(request)
                exportedURL = outcome.url
            } catch {
                model.alert = EditorAlert(
                    title: L10n.t("Export failed"),
                    message: error.localizedDescription,
                    nextStep: L10n.t("Try again.")
                )
            }
            isExporting = false
        }
    }

    private func saveToPhotos(_ url: URL) {
        isSavingToPhotos = true
        Task {
            let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard authorization == .authorized || authorization == .limited else {
                model.alert = EditorAlert(
                    title: L10n.t("Photos access is needed"),
                    message: L10n.t("Allow LumaHarbor to add exported photos in Settings."),
                    nextStep: nil
                )
                isSavingToPhotos = false
                return
            }

            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                }
            } catch {
                model.alert = EditorAlert(
                    title: L10n.t("Couldn't save to Photos"),
                    message: error.localizedDescription,
                    nextStep: L10n.t("Try again.")
                )
            }
            isSavingToPhotos = false
        }
    }

    // MARK: - Work mode: trailing dock

    private var trailingDockPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                saveStatusIndicator
                undoRedoControls
                Divider()
                BasicAdjustmentPanel(editor: editor)
            }
            .padding()
        }
        .frame(width: 320)
        .background(.thickMaterial)
    }

    // MARK: - Work mode: bottom drawer

    private var bottomDrawerPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                saveStatusIndicator
                undoRedoControls
                Divider()
                BasicAdjustmentPanel(editor: editor)
            }
            .padding()
        }
    }

    // MARK: - Focus mode: floating panel

    private var floatingPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            floatingPanelHeader
            saveStatusIndicator
            undoRedoControls
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    BasicAdjustmentPanel(editor: editor)
                }
            }
            .frame(maxHeight: 420)
        }
        .padding()
        .frame(width: 320)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(radius: 12)
    }

    /// Measures the floating panel's actual rendered size into
    /// `floatingPanelMeasuredSize`, so `PadFloatingPanelLayout.clampedOffset`
    /// always clamps against the real size rather than a hardcoded guess —
    /// its height varies slightly with content/dynamic type, and this
    /// stays correct without depending on either.
    private var floatingPanelSizeReader: some View {
        GeometryReader { proxy in
            Color.clear
                .preference(key: FloatingPanelSizeKey.self, value: proxy.size)
        }
        .onPreferenceChange(FloatingPanelSizeKey.self) { size in
            guard size != .zero else { return }
            floatingPanelMeasuredSize = size
        }
    }

    /// A dedicated drag handle, not the whole panel — the panel also
    /// contains `Slider`s (via `BasicAdjustmentPanel`), and a drag
    /// gesture covering the entire panel would fight their own drag
    /// gestures instead of letting them work.
    private var floatingPanelHeader: some View {
        HStack {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(L10n.t("Adjustments"))
                .font(.headline)
            Spacer()
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(L10n.t("Adjustments")))
        .accessibilityHint(Text(L10n.t("Drag to move this panel.")))
        .gesture(
            DragGesture()
                .updating($floatingPanelDragTranslation) { value, state, _ in
                    state = value.translation
                }
                .onEnded { value in
                    let proposed = CGSize(
                        width: workspaceState.floatingPanelOffset.width + value.translation.width,
                        height: workspaceState.floatingPanelOffset.height + value.translation.height
                    )
                    workspaceState.floatingPanelOffset = PadFloatingPanelLayout.clampedOffset(
                        proposedOffset: proposed,
                        panelOrigin: Self.floatingPanelDefaultOrigin,
                        panelSize: floatingPanelMeasuredSize,
                        availableSize: availableSize,
                        minimumVisibleEdge: Self.floatingPanelMinimumVisibleEdge
                    )
                }
        )
    }

    /// Re-clamps whatever offset is already committed against the current
    /// `availableSize` — called on every resize/rotation/Split View change,
    /// so a panel left near an edge before the area shrank doesn't end up
    /// stranded outside it.
    private func reclampFloatingPanelOffset() {
        workspaceState.floatingPanelOffset = PadFloatingPanelLayout.clampedOffset(
            proposedOffset: workspaceState.floatingPanelOffset,
            panelOrigin: Self.floatingPanelDefaultOrigin,
            panelSize: floatingPanelMeasuredSize,
            availableSize: availableSize,
            minimumVisibleEdge: Self.floatingPanelMinimumVisibleEdge
        )
    }

    // MARK: - Shared controls

    @ViewBuilder
    private var saveStatusIndicator: some View {
        switch editor.saveState {
        case .unchanged, .saved:
            Label(L10n.t("Saved"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .pending:
            Label(L10n.t("Unsaved"), systemImage: "clock")
                .foregroundStyle(.secondary)
        case .saving:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(L10n.t("Saving…"))
            }
            .foregroundStyle(.secondary)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label(L10n.t("Save failed"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L10n.t("Your RAW original was not changed."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var undoRedoControls: some View {
        HStack {
            Button {
                editor.undo()
            } label: {
                Label(L10n.t("Undo"), systemImage: "arrow.uturn.backward")
            }
            .disabled(!editor.canUndo)
            .accessibilityLabel(Text(L10n.t("Undo")))

            Button {
                editor.redo()
            } label: {
                Label(L10n.t("Redo"), systemImage: "arrow.uturn.forward")
            }
            .disabled(!editor.canRedo)
            .accessibilityLabel(Text(L10n.t("Redo")))

            Spacer()
        }
    }

    private func alertBody(_ alert: EditorAlert) -> String {
        [alert.message, alert.nextStep].compactMap { $0 }.joined(separator: "\n\n")
    }
}

/// Carries the floating panel's own measured size out of
/// `PadEditorView.floatingPanelSizeReader`'s background `GeometryReader`.
private struct FloatingPanelSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// Wraps an already-exported photo file so SwiftUI's `fileExporter` can
/// hand it to the system Files picker (spec §5.5.1's "Save to Files")
/// without this view re-encoding or re-deriving anything: the bytes were
/// already produced by `PhotoExporter` in `exportFullResolution()`, and
/// `fileWrapper(configuration:)` below just reads them back off disk.
private struct ExportedPhotoFileDocument: FileDocument {
    /// Never actually read back through this type -- `fileExporter` only
    /// writes -- but the protocol requires a non-empty answer for the
    /// picker to treat this as an exportable kind at all.
    static var readableContentTypes: [UTType] { [.jpeg, .heic, .png, .tiff] }
    static var writableContentTypes: [UTType] { [.jpeg, .heic, .png, .tiff] }

    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: fileURL, options: .immediate)
    }
}
