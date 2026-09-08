import AppKit
import SwiftUI
import Localization

/// Spec §6.2's three regions: library status on the left, preview and filmstrip
/// in the middle, adjustments on the right.
///
/// Phase 2.3 (spec §6.3, Mac focus workspace): whether the sidebar,
/// inspector, and filmstrip are showing -- plus the inspector's width and
/// whether focus mode is hiding all three -- are pure `@AppStorage`
/// preferences, never written to a photo's sidecar. `WorkspaceLayoutState`
/// holds the actual policy (focus mode's effect on visibility, the width
/// clamp); this view only reads/writes the five `@AppStorage` values that
/// back its fields and renders accordingly.
struct RootView: View {
    @EnvironmentObject private var model: LibraryViewModel
    /// Roadmap Phase 5 Task 5.3. Same key `SettingsView`'s picker binds, so
    /// a change there is visible here immediately.
    @AppStorage("appTheme") private var theme: AppTheme = .default

    @AppStorage(WorkspaceLayoutState.StorageKey.showSidebar) private var showSidebar = true
    @AppStorage(WorkspaceLayoutState.StorageKey.showInspector) private var showInspector = true
    @AppStorage(WorkspaceLayoutState.StorageKey.showFilmstrip) private var showFilmstrip = true
    @AppStorage(WorkspaceLayoutState.StorageKey.focusMode) private var focusMode = false
    @AppStorage(WorkspaceLayoutState.StorageKey.inspectorWidth) private var inspectorWidth = WorkspaceLayoutState.defaultInspectorWidth

    /// The inspector width at the start of the current divider drag, so
    /// each `DragGesture` update is `baseline - translation` (dragging left
    /// widens the right-hand inspector) rather than accumulating error
    /// across frames.
    @State private var inspectorWidthDragBaseline: Double?

    private var layout: WorkspaceLayoutState {
        WorkspaceLayoutState(
            showSidebar: showSidebar,
            showInspector: showInspector,
            showFilmstrip: showFilmstrip,
            focusMode: focusMode,
            inspectorWidth: inspectorWidth
        )
    }

    /// `NavigationSplitView`'s own sidebar collapse (its built-in toolbar
    /// button, or a user drag) is kept in sync with `showSidebar` in both
    /// directions -- except while focus mode is on, when the native control
    /// is ignored so it can never silently overwrite the preference focus
    /// mode is temporarily overriding.
    private var columnVisibilityBinding: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { layout.effectiveShowSidebar ? .all : .detailOnly },
            set: { newValue in
                guard !focusMode else { return }
                showSidebar = newValue != .detailOnly
            }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: columnVisibilityBinding) {
            LibrarySidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            HStack(spacing: 0) {
                centerPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if layout.effectiveShowInspector {
                    inspectorResizeHandle
                    InspectorView()
                        .frame(width: layout.inspectorWidth)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                workspaceMenu
            }
        }
        .preferredColorScheme(theme.colorScheme)
        .task {
            await model.bootstrap()
        }
        .alert(item: $model.alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text([alert.message, alert.nextStep]
                    .compactMap { $0 }
                    .joined(separator: "\n\n")),
                dismissButton: .default(Text(L10n.t("OK")))
            )
        }
        .sheet(isPresented: $model.isShowingExportSheet) {
            ExportSheet()
                .environmentObject(model)
                .preferredColorScheme(theme.colorScheme)
        }
        .sheet(isPresented: $model.isShowingBatchExportSheet) {
            BatchExportSheet()
                .environmentObject(model)
                .preferredColorScheme(theme.colorScheme)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            // Cheapest reliable way to notice the SSD came back or went away.
            Task { await model.refreshAvailability() }
        }
    }

    /// Icon + localized label (spec §6.3: "不能使用三個外觀相同的圓角文字按鈕代替" for the
    /// inspector tabs applies just as much here -- one clearly labelled
    /// entry point, not several look-alike buttons).
    private var workspaceMenu: some View {
        Menu {
            Toggle(L10n.t("Show Sidebar"), isOn: $showSidebar)
            Toggle(L10n.t("Show Inspector"), isOn: $showInspector)
            Toggle(L10n.t("Show Filmstrip"), isOn: $showFilmstrip)
            Divider()
            Toggle(L10n.t("Distraction-Free Mode"), isOn: $focusMode)
            Divider()
            Slider(
                value: inspectorWidthBinding,
                in: WorkspaceLayoutState.minimumInspectorWidth...WorkspaceLayoutState.maximumInspectorWidth
            ) {
                Text(L10n.t("Inspector Width"))
            }
            .disabled(!showInspector)
        } label: {
            Label(L10n.t("Workspace"), systemImage: "sidebar.squares.left")
        }
        .help(L10n.t("Show, hide, or resize workspace panels"))
    }

    /// Reads/writes the same clamped value the drag handle below applies,
    /// so a value restored from an older or corrupted `@AppStorage` entry
    /// can never put the slider outside its own declared range.
    private var inspectorWidthBinding: Binding<Double> {
        Binding(
            get: { WorkspaceLayoutState.clampedInspectorWidth(inspectorWidth) },
            set: { inspectorWidth = WorkspaceLayoutState.clampedInspectorWidth($0) }
        )
    }

    /// A wide, invisible hit area centred on the visible `Divider()`, so the
    /// inspector is comfortably resizable without needing pixel-perfect
    /// aim on a 1pt line (spec §6.3: inspector width adjustable, clamped to
    /// 280-420 pt -- the same clamp `WorkspaceLayoutState.clampedInspectorWidth`
    /// enforces, applied here on every drag update rather than once at the
    /// end, so the inspector never visibly overshoots mid-drag).
    private var inspectorResizeHandle: some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let baseline = inspectorWidthDragBaseline ?? inspectorWidth
                                inspectorWidthDragBaseline = baseline
                                inspectorWidth = WorkspaceLayoutState.clampedInspectorWidth(
                                    baseline - value.translation.width
                                )
                            }
                            .onEnded { _ in inspectorWidthDragBaseline = nil }
                    )
                    .onHover { hovering in
                        if hovering {
                            NSCursor.resizeLeftRight.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
            }
    }

    @ViewBuilder
    private var centerPane: some View {
        if model.libraries.isEmpty {
            WelcomeView()
        } else if model.selectedPhotoID == nil {
            LibraryGridView()
        } else {
            EditorView()
        }
    }
}

/// First launch: spec §6.1 asks for a single, obvious "add a photo folder".
struct WelcomeView: View {
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.badge.plus")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.secondary)

            Text(L10n.t("Add a photo folder"))
                .font(.title2.weight(.semibold))

            Text(L10n.t(
                "Choose a folder on your drive. LumaHarbor reads your RAW files where they are and never moves or changes them."
            ))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            Button(L10n.t("Add Photo Folder…")) {
                model.presentAddFolderPanel()
            }
            .keyboardShortcut("o", modifiers: .command)
            .controlSize(.large)
            .padding(.top, 4)

            if let failure = model.startupFailure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}
