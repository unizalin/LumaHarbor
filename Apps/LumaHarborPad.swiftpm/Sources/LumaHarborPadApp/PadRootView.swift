import SwiftUI
import UniformTypeIdentifiers

struct PadRootView: View {
    @State private var isImporting = false
    @State private var selectedURL: URL?

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Open a RAW photo",
                systemImage: "photo.badge.plus",
                description: Text("Choose a photo from Files or an external drive.")
            )
            .toolbar {
                Button("Open RAW…") {
                    isImporting = true
                }
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.image, .data],
                allowsMultipleSelection: false
            ) { result in
                selectedURL = try? result.get().first
            }
        }
    }
}
