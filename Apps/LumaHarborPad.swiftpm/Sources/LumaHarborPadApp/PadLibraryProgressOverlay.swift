import SwiftUI

/// A lightweight blocking progress treatment for operations that are longer
/// than a tap but shorter than a separate task screen: registering an
/// external source, resolving a photo before handing it to the editor, etc.
struct PadLibraryProgressOverlay: View {
    let title: String
    var message: String?

    var body: some View {
        ZStack {
            Color.black.opacity(0.12)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)

                Text(title)
                    .font(.headline)

                if let message {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.vertical, 22)
            .padding(.horizontal, 26)
            .frame(maxWidth: 320)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .accessibilityElement(children: .combine)
        }
        .transition(.opacity)
    }
}
