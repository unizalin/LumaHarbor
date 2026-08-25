import AdjustmentUI
import EditorCore
import Localization
import SwiftUI

/// The adaptive editing surface (Task 7): the same canvas and the same ten
/// basic sliders as Task 6, but the *container* the sliders live in adapts
/// to the available size and to an explicit work/focus toggle —
/// `PadEditorLayoutPolicy` decides trailing dock vs. bottom drawer purely
/// from width/height, and `workspaceMode` (view-local `@State`, never
/// touching `EditorSession`) decides work vs. focus.
///
/// `editor` — and therefore the open photo, its adjustments, and its undo
/// stack — is the same `EditorSession` instance across every layout this
/// view ever renders; resizing, rotating, or toggling work/focus only ever
/// changes which container the same controls render inside, never what
/// document is open or what state it holds.
struct PadEditorView: View {
    @ObservedObject var model: PadEditorModel
    @ObservedObject private var editor: EditorSession

    /// Work vs. focus. Pure presentation state — see `PadWorkspaceMode`'s
    /// own documentation for why switching this can never call an editor
    /// API, and why it lives here as plain `@State` rather than anywhere
    /// that would persist it or route it through `EditorSession`.
    @State private var workspaceMode: PadWorkspaceMode = .work

    /// Where the focus-mode floating panel currently sits, relative to
    /// its default position. View-local `@State`, exactly like
    /// `workspaceMode` — resets if this view itself is torn down and
    /// recreated (a fresh document opening), but survives every work/
    /// focus toggle and every resize/rotation in between.
    @State private var floatingPanelOffset: CGSize = .zero
    @GestureState private var floatingPanelDragTranslation: CGSize = .zero

    /// A minimal pinch-to-zoom for the canvas — view-local `@State` for
    /// the same reason the floating panel's position is: it must survive
    /// a work/focus toggle or a resize/rotation, and it must never be
    /// mistaken for an edit (it never touches `EditorSession`).
    @State private var canvasScale: CGFloat = 1
    @GestureState private var canvasMagnification: CGFloat = 1

    private static let minimumCanvasScale: CGFloat = 1
    private static let maximumCanvasScale: CGFloat = 5

    init(model: PadEditorModel) {
        self.model = model
        self.editor = model.editor
    }

    var body: some View {
        GeometryReader { proxy in
            workspaceContent(availableSize: proxy.size)
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
        }
        .alert(item: $editor.alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alertBody(alert)),
                dismissButton: .default(Text(L10n.t("OK")))
            )
        }
    }

    // MARK: - Work / focus toggle

    private var workspaceModeToggle: some View {
        // Switching `workspaceMode` is the *only* thing this button does —
        // no `editor` call of any kind, so it can never create an undo
        // entry, touch adjustments, or open/close anything.
        Button {
            workspaceMode = (workspaceMode == .work) ? .focus : .work
        } label: {
            switch workspaceMode {
            case .work:
                Label(L10n.t("Focus Mode"), systemImage: "rectangle.inset.filled")
            case .focus:
                Label(L10n.t("Work Mode"), systemImage: "rectangle.split.2x1")
            }
        }
        // Explicit, not left to `Label`'s own inference — a toolbar can
        // render this icon-only depending on available space, and an
        // icon-only control must still have a real accessibility label.
        .accessibilityLabel(Text(workspaceMode == .work ? L10n.t("Focus Mode") : L10n.t("Work Mode")))
    }

    // MARK: - Layout selection

    @ViewBuilder
    private func workspaceContent(availableSize: CGSize) -> some View {
        switch workspaceMode {
        case .work:
            workLayout(availableSize: availableSize)
        case .focus:
            focusLayout
        }
    }

    @ViewBuilder
    private func workLayout(availableSize: CGSize) -> some View {
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
                .sheet(isPresented: .constant(true)) {
                    bottomDrawerPanel
                        .presentationDetents([.height(220), .medium, .large])
                        .presentationDragIndicator(.visible)
                        // A drawer that could be swiped away entirely
                        // would leave the user with no way back to the
                        // controls short of resizing/rotating the window
                        // again — resizing between the three detents
                        // above is still fully interactive.
                        .interactiveDismissDisabled(true)
                        .presentationBackgroundInteraction(.enabled)
                }
        }
    }

    private var focusLayout: some View {
        ZStack(alignment: .topLeading) {
            canvas
            floatingPanel
                .offset(
                    x: floatingPanelOffset.width + floatingPanelDragTranslation.width,
                    y: floatingPanelOffset.height + floatingPanelDragTranslation.height
                )
                .padding(24)
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
                    .scaleEffect(canvasScale * canvasMagnification)
                    .gesture(
                        MagnificationGesture()
                            .updating($canvasMagnification) { value, state, _ in
                                state = value
                            }
                            .onEnded { value in
                                let proposed = canvasScale * value
                                canvasScale = min(max(proposed, Self.minimumCanvasScale), Self.maximumCanvasScale)
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

    // MARK: - Work mode: trailing dock

    private var trailingDockPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
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
                    floatingPanelOffset.width += value.translation.width
                    floatingPanelOffset.height += value.translation.height
                }
        )
    }

    // MARK: - Shared controls

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
