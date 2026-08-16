import SwiftUI

/// Spec §6.2's three regions: library status on the left, preview and filmstrip
/// in the middle, adjustments on the right.
struct RootView: View {
    @EnvironmentObject private var model: LibraryViewModel
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            LibrarySidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            HStack(spacing: 0) {
                centerPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                InspectorView()
                    .frame(width: 300)
            }
        }
        .task {
            await model.bootstrap()
        }
        .alert(item: $model.alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text([alert.message, alert.nextStep]
                    .compactMap { $0 }
                    .joined(separator: "\n\n")),
                dismissButton: .default(Text("OK"))
            )
        }
        .sheet(isPresented: $model.isShowingExportSheet) {
            ExportSheet()
                .environmentObject(model)
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

            Text("Add a photo folder")
                .font(.title2.weight(.semibold))

            Text("""
                 Choose a folder on your drive. LumaHarbor reads your RAW files \
                 where they are and never moves or changes them.
                 """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            Button("Add Photo Folder…") {
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
