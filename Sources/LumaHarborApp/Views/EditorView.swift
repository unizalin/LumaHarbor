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
    /// The persistent "pinned" state a click toggles. Kept separate from
    /// `model.editor.isShowingOriginal`, which also gets driven transiently
    /// while a hold is in progress.
    @State private var isPinned = false
    @State private var pressBeganAt: Date?
    /// Below this, a press+release is a click; at or above it, a hold-to-peek.
    private static let holdThreshold: TimeInterval = 0.25

    var body: some View {
        Button {
            // Intentionally empty. A first attempt kept the toggle here
            // alongside the gesture below, but `minimumDistance: 0` means the
            // gesture also fires for a plain click, not just a drag -- so a
            // click ran both this action *and* the gesture, and the two
            // fought over `isShowingOriginal` (found manually 2026-08-18:
            // clicking always ended up pinned to the original, never toggling
            // back). A second attempt moved the toggle into the gesture but
            // deferred "peek" through an async `Task.sleep`; that made both
            // click *and* hold stop working (found manually 2026-08-19) --
            // an active drag gesture runs the run loop in event-tracking
            // mode, which can starve a Task-based timer until the mouse is
            // released, i.e. after the decision was already needed. This
            // version has exactly one thing deciding `isShowingOriginal`,
            // computed synchronously from real press/release timestamps, so
            // there is nothing left to race and nothing waiting on a timer
            // that a live drag can starve.
        } label: {
            Label("Original", systemImage: "rectangle.righthalf.inset.filled.arrow.right")
        }
        .disabled(!model.editor.canCompareWithOriginal)
        .help("Hold to compare with the original, or click to pin it")
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard model.editor.canCompareWithOriginal else { return }
                    if pressBeganAt == nil {
                        pressBeganAt = Date()
                    }
                    // Immediate feedback for the whole press, tap or hold
                    // alike -- onEnded below decides what happens on release.
                    model.editor.isShowingOriginal = true
                }
                .onEnded { _ in
                    defer { pressBeganAt = nil }
                    let heldLongEnough = pressBeganAt.map {
                        Date().timeIntervalSince($0) >= Self.holdThreshold
                    } ?? false
                    if heldLongEnough {
                        // Hold-to-peek ends: back to whatever was pinned.
                        model.editor.isShowingOriginal = isPinned
                    } else {
                        // A quick tap: toggle the pin.
                        isPinned.toggle()
                        model.editor.isShowingOriginal = isPinned
                    }
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
