import Foundation
import AdjustmentUI
import Localization
import RawProcessingCore
import SwiftUI
import UniformTypeIdentifiers

struct PadExportOptionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var options: PadExportOptions
    let onExport: () -> Void
    @State private var maximumDimensionText: String
    @State private var dpiText: String

    init(options: Binding<PadExportOptions>, onExport: @escaping () -> Void) {
        self._options = options
        self.onExport = onExport
        self._maximumDimensionText = State(initialValue: options.wrappedValue.maximumDimension.map(String.init) ?? "")
        self._dpiText = State(initialValue: options.wrappedValue.dpi.map { String(Int($0)) } ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.t("Format")) {
                    Picker(L10n.t("Format"), selection: $options.format) {
                        ForEach(ExportFormat.allCases, id: \.self) { format in
                            Text(format.displayName).tag(format)
                        }
                    }

                    if options.format.usesQuality {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(L10n.t("Quality"))
                                Spacer()
                                Text("\(Int(options.qualityPercentage.rounded()))%")
                                    .monospacedDigit()
                            }
                            Slider(value: $options.quality, in: 0...1, step: 0.01)
                        }
                    }

                    if options.format.supportsBitDepthChoice {
                        Picker(L10n.t("Bit Depth"), selection: $options.bitDepth) {
                            ForEach(ExportBitDepth.allCases, id: \.self) { depth in
                                Text(depth.displayName).tag(depth)
                            }
                        }
                    }
                }

                Section(L10n.t("Size")) {
                    TextField(L10n.t("Size"), text: $maximumDimensionText)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    Text(L10n.t("Leave blank to keep the full resolution."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(L10n.t("DPI")) {
                    TextField(L10n.t("DPI"), text: $dpiText)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    Text(L10n.t("Leave blank to use the encoder default."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(L10n.t("EXIF")) {
                    Picker(L10n.t("EXIF"), selection: $options.exifRetentionPolicy) {
                        ForEach(ExifRetentionPolicy.allCases, id: \.self) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    }
                }

                Section(L10n.t("Collision")) {
                    Picker(L10n.t("Collision"), selection: $options.collisionPolicy) {
                        ForEach(ExportCollisionPolicy.allCases, id: \.self) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    }
                }
            }
            .navigationTitle(L10n.t("Export"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("Export")) {
                        commitOptionalFields()
                        onExport()
                    }
                }
            }
        }
    }

    private func commitOptionalFields() {
        let dimension = Int(maximumDimensionText.trimmingCharacters(in: .whitespacesAndNewlines))
        options.setMaximumDimension(dimension)
        let dpi = Double(dpiText.trimmingCharacters(in: .whitespacesAndNewlines))
        options.setDPI(dpi)
    }
}

/// Wraps an already-exported photo file so SwiftUI's `fileExporter` can
/// hand it to the system Files picker (spec §5.5.1's "Save to Files")
/// without this view re-encoding or re-deriving anything: the bytes were
/// already produced by `PhotoExporter` in `exportFullResolution()`, and
/// `fileWrapper(configuration:)` below just reads them back off disk.
struct ExportedPhotoFileDocument: FileDocument {
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
