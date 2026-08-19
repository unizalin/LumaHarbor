import PhotoLibraryCore
import SwiftUI

/// Centre pane: the large preview plus the filmstrip (spec §6.2).
struct EditorView: View {
    @EnvironmentObject private var model: LibraryViewModel
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        VStack(spacing: 0) {
            previewArea
            Divider()
            FilmstripView()
                .frame(height: 108)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .navigationTitle(model.selectedPhoto?.filename ?? "LumaHarbor")
        .toolbar { toolbarContent }
        .alert(item: Binding(
            get: { model.editor.alert },
            set: { model.editor.alert = $0 }
        )) { alert in
            Alert(
                title: Text(alert.title),
                message: Text([alert.message, alert.nextStep]
                    .compactMap { $0 }
                    .joined(separator: "\n\n")),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var previewArea: some View {
        GeometryReader { geometry in
            ZStack {
                Color(nsColor: .underPageBackgroundColor)

                if let image = model.editor.displayedImage {
                    Image(decorative: image, scale: 1, orientation: .up)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(16)
                } else {
                    ProgressView("Decoding RAW…")
                        .controlSize(.large)
                }

                if model.editor.isShowingOriginal {
                    Text("Original")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.thinMaterial, in: Capsule())
                        .padding(16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            // Decode at the size actually on screen, not at native resolution
            // (spec §9).
            .onChange(of: geometry.size) { _, newSize in
                updatePreviewSize(newSize)
            }
            .onAppear {
                updatePreviewSize(geometry.size)
            }
        }
    }

    private func updatePreviewSize(_ size: CGSize) {
        let longestEdge = max(size.width, size.height) * displayScale
        guard longestEdge.isFinite, longestEdge > 0 else { return }
        // Round to a step so a live window resize doesn't re-decode on every
        // frame of the drag.
        let stepped = (Int(longestEdge) / 256 + 1) * 256
        if abs(stepped - model.editor.previewPixelDimension) >= 256 {
            model.editor.previewPixelDimension = stepped
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                model.requestSelectPhoto(nil)
            } label: {
                Label("Back to Library", systemImage: "square.grid.2x2")
            }
            .help("Back to the library grid")
        }

        ToolbarItemGroup(placement: .principal) {
            CompareButton()

            Button {
                model.editor.undo()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(!model.editor.canUndo)

            Button {
                model.editor.redo()
            } label: {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
            .disabled(!model.editor.canRedo)
        }

        ToolbarItem(placement: .automatic) {
            SaveStateLabel(state: model.editor.saveState)
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                model.isShowingExportSheet = true
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(model.selectedPhoto == nil)
            .help("Export a full-resolution JPEG")
        }
    }
}

/// Hold to peek at the original, click to pin it (spec §6.2).
private struct CompareButton: View {
    @EnvironmentObject private var model: LibraryViewModel
    @State private var isHolding = false

    var body: some View {
        Button {
            model.editor.isShowingOriginal.toggle()
        } label: {
            Label("Original", systemImage: "rectangle.righthalf.inset.filled.arrow.right")
        }
        .disabled(!model.editor.canCompareWithOriginal)
        .help("Hold to compare with the original, or click to pin it")
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isHolding, model.editor.canCompareWithOriginal else { return }
                    isHolding = true
                    model.editor.isShowingOriginal = true
                }
                .onEnded { _ in
                    guard isHolding else { return }
                    isHolding = false
                    model.editor.isShowingOriginal = false
                }
        )
    }
}

private struct SaveStateLabel: View {
    let state: SaveState

    var body: some View {
        switch state {
        case .unchanged:
            EmptyView()
        case .pending:
            Label("Unsaved", systemImage: "circle.dotted")
                .foregroundStyle(.secondary)
        case .saving:
            Label("Saving…", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
        case .saved:
            Label("Saved", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label("Not saved", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help(message)
        }
    }
}
