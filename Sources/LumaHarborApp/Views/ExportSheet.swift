import SwiftUI

/// Spec §6.3: one photo at a time, choose destination and quality, no silent
/// overwrite, cancellable.
struct ExportSheet: View {
    @EnvironmentObject private var model: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    @AppStorage("export.jpegQuality") private var quality = 0.9

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export JPEG")
                .font(.title3.weight(.semibold))

            if let photo = model.selectedPhoto {
                LabeledContent("Photo", value: photo.filename)
                LabeledContent("Size") {
                    Text(sizeDescription(photo.metadata.pixelWidth, photo.metadata.pixelHeight))
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("JPEG quality")
                    Spacer()
                    Text(verbatim: "\(Int((quality * 100).rounded()))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $quality, in: 0.4...1.0)
            }

            Text("""
                 LumaHarbor re-decodes the original RAW at full resolution and \
                 tags the result sRGB. If a file with the same name already \
                 exists, a number is added — nothing is overwritten.
                 """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let state = model.exportState {
                Divider()
                if state.isFinished {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("\(String(localized: "Exported")) \(state.filename)")
                        Spacer()
                        Button("Show in Finder") { model.revealExportInFinder() }
                            .controlSize(.small)
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("\(String(localized: "Exporting")) \(state.filename)…")
                        Spacer()
                        Button("Cancel") { model.cancelExport() }
                            .controlSize(.small)
                    }
                }
            }

            Divider()

            HStack {
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Choose Destination…") {
                    model.presentExportPanel(quality: quality)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.selectedPhoto == nil || model.isExporting)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func sizeDescription(_ width: Int, _ height: Int) -> String {
        guard width > 0, height > 0 else { return String(localized: "Unknown") }
        let megapixels = Double(width * height) / 1_000_000
        return String(format: "%d × %d (%.1f MP)", width, height, megapixels)
    }
}
