import AdjustmentUI
import EditorCore
import Localization
import PresetCore
import SwiftUI

/// Owns the one Inspector surface in both its trailing-dock and movable
/// compact presentations. The parent owns only document-scoped geometry and
/// receives movement/minimize events through closures.
struct PadEditorInspectorContainer: View {
    @ObservedObject var inspector: PadInspectorCoordinator
    @ObservedObject var navigation: InspectorNavigationModel
    @ObservedObject var editor: EditorSession
    @ObservedObject var presetLibrary: PadPresetLibrary
    @ObservedObject var library: PadLibraryModel
    @ObservedObject var batchCoordinator: PadBatchAdjustmentCoordinator
    @Binding var isMinimized: Bool
    @Binding var floatingPanelOffset: CGSize
    let availableSize: CGSize
    let floatingPanelMeasuredSize: CGSize
    let presentation: PadInspectorPresentation
    let dockWidth: CGFloat?
    let onMeasurePanel: (CGSize) -> Void
    let onCommitDrag: (CGSize, CGSize) -> Void
    let onMinimize: () -> Void
    let onRestore: () -> Void
    let isRestoreTile: Bool

    @GestureState private var dragTranslation: CGSize = .zero

    var body: some View {
        if isRestoreTile {
            restoreTile
        } else {
            switch presentation {
            case .trailingDock:
                inspectorPanelContent(showsDomainBar: false)
                    .frame(width: dockWidth ?? PadEditorLayoutPolicy.minimumInspectorWidth)
                    .background(.thickMaterial)
            case .bottomDrawer:
                movablePanel
            }
        }
    }

    private var movablePanel: some View {
        inspectorPanelContent(showsDomainBar: true)
            .frame(width: PadEditorLayoutPolicy.movableInspectorWidth(for: availableSize))
            .frame(maxHeight: PadEditorLayoutPolicy.movableInspectorHeight(for: availableSize))
            .background(
                .thickMaterial,
                in: RoundedRectangle(cornerRadius: PadBottomDrawerMetrics.cornerRadius, style: .continuous)
            )
            .shadow(radius: 12)
            .background(sizeReader)
            .offset(
                x: movableInspectorOrigin.x + floatingPanelOffset.width + dragTranslation.width,
                y: movableInspectorOrigin.y + floatingPanelOffset.height + dragTranslation.height
            )
    }

    private var movableInspectorOrigin: CGPoint {
        PadEditorLayoutPolicy.movableInspectorOrigin(
            for: availableSize,
            panelSize: floatingPanelMeasuredSize
        )
    }

    private var sizeReader: some View {
        GeometryReader { proxy in
            Color.clear
                .preference(key: FloatingPanelSizeKey.self, value: proxy.size)
        }
        .onPreferenceChange(FloatingPanelSizeKey.self) { size in
            guard size != .zero else { return }
            onMeasurePanel(size)
        }
    }

    @ViewBuilder
    private func inspectorPanelContent(showsDomainBar: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            inspectorPanelHeader
            Divider()
            PadInspectorHost(
                inspector: inspector,
                navigation: navigation,
                editor: editor,
                presetLibrary: presetLibrary,
                library: library,
                batchCoordinator: batchCoordinator,
                showsDomainBar: showsDomainBar
            )
        }
    }

    private var inspectorPanelHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                inspectorPanelDragHandle
                saveStatusIndicator
                undoRedoControls
            }
            Spacer(minLength: 0)
            inspectorMinimizeButton
        }
        .padding()
    }

    private var inspectorPanelDragHandle: some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(L10n.t("Adjustments"))
                .font(.headline)
            Text(L10n.t("Drag to move this panel."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(L10n.t("Adjustments")))
        .accessibilityHint(Text(L10n.t("Drag to move this panel.")))
        .gesture(
            DragGesture(minimumDistance: 8)
                .updating($dragTranslation) { value, state, _ in
                    if presentation == .bottomDrawer {
                        state = value.translation
                    }
                }
                .onEnded { value in
                    guard presentation == .bottomDrawer else { return }
                    if PadEditorLayoutPolicy.shouldDismissMovableInspector(for: value.translation) {
                        onMinimize()
                    } else {
                        onCommitDrag(value.translation, availableSize)
                    }
                }
        )
    }

    private var inspectorMinimizeButton: some View {
        Button(action: onMinimize) {
            Image(systemName: "xmark.circle.fill")
                .imageScale(.large)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary)
        .accessibilityLabel(Text(L10n.t("Hide Inspector")))
        .accessibilityHint(Text(L10n.t("Show Inspector")))
        .help(Text(L10n.t("Minimize Inspector")))
    }

    private var restoreTile: some View {
        Button(action: onRestore) {
            Image(systemName: "slider.horizontal.3")
                .font(.headline)
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityLabel(Text(L10n.t("Show Inspector")))
        .help(Text(L10n.t("Show Inspector")))
    }

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
}

private struct FloatingPanelSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}
