import SwiftUI
import Localization
import RawProcessingCore

/// Spec §6.11: one photo at a time, choose format, quality/bit depth, size
/// caps, DPI and EXIF retention, then choose a destination -- no silent
/// overwrite, cancellable.
struct ExportSheet: View {
    @EnvironmentObject private var model: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    @AppStorage("export.format") private var format: ExportFormat = .jpeg
    @AppStorage("export.quality") private var quality = 0.9
    @AppStorage("export.bitDepth") private var bitDepth: ExportBitDepth = .eightBit
    @AppStorage("export.exifRetentionPolicy") private var exifRetentionPolicy: ExifRetentionPolicy = .preserveAll
    @AppStorage("export.namingTemplate") private var namingTemplate: ExportNamingTemplate = .default
    @AppStorage("export.collisionPolicy") private var collisionPolicy: ExportCollisionPolicy = .default
    @AppStorage("export.watermarkEnabled") private var watermarkEnabled = false
    @AppStorage("export.watermarkText") private var watermarkText = ""
    @AppStorage("export.watermarkPosition") private var watermarkPosition: Watermark.Position = .bottomRight
    @AppStorage("export.watermarkOpacity") private var watermarkOpacity = 0.6
    @AppStorage("export.watermarkSizeFraction") private var watermarkSizeFraction = 0.04
    @State private var maximumWidthText = ""
    @State private var maximumHeightText = ""
    @State private var dpiText = ""

    private var maximumWidth: Int? { Int(maximumWidthText) }
    private var maximumHeight: Int? { Int(maximumHeightText) }
    private var dpi: Double? { Double(dpiText) }

    /// `nil` unless the toggle is on and there is actual text -- an empty
    /// or disabled watermark must never reach `ExportRequest` as a non-nil
    /// value (see `WatermarkRenderer.apply(_:to:)`'s own no-op guard, which
    /// this mirrors rather than relies on alone).
    private var watermark: Watermark? {
        guard watermarkEnabled, !watermarkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return Watermark(text: watermarkText, position: watermarkPosition, opacity: watermarkOpacity, sizeFraction: watermarkSizeFraction)
    }

    private var options: MacExportOptions {
        MacExportOptions(
            format: format,
            quality: quality,
            bitDepth: bitDepth,
            maximumWidth: maximumWidth,
            maximumHeight: maximumHeight,
            dpi: dpi,
            exifRetentionPolicy: exifRetentionPolicy,
            namingTemplate: namingTemplate,
            collisionPolicy: collisionPolicy,
            watermark: watermark
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.t("Export Photo"))
                .font(.title3.weight(.semibold))

            if let photo = model.selectedPhoto {
                LabeledContent(L10n.t("Photo"), value: photo.filename)
                LabeledContent(L10n.t("Size")) {
                    Text(sizeDescription(photo.metadata.pixelWidth, photo.metadata.pixelHeight))
                }
            }

            formatPicker

            if format.usesQuality {
                qualitySlider
            }
            if format.supportsBitDepthChoice {
                bitDepthPicker
            }

            resizeFields
            dpiField
            exifPolicyPicker
            namingPicker
            collisionPolicyPicker
            watermarkSection

            Text(L10n.t(
                "LumaHarbor re-decodes the original RAW at full resolution and tags the result sRGB. If a file with the same name already exists, a number is added — nothing is overwritten."
            ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let state = model.exportState {
                Divider()
                if state.isFinished {
                    if state.wasSkipped {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.uturn.forward.circle")
                                .foregroundStyle(.secondary)
                            Text("\(L10n.t("Skipped")) \(state.filename)")
                            Spacer()
                        }
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("\(L10n.t("Exported")) \(state.filename)")
                            Spacer()
                            Button(L10n.t("Show in Finder")) { model.revealExportInFinder() }
                                .controlSize(.small)
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("\(L10n.t("Exporting")) \(state.filename)…")
                        Spacer()
                        Button(L10n.t("Cancel")) { model.cancelExport() }
                            .controlSize(.small)
                    }
                }
            }

            Divider()

            HStack {
                Button(L10n.t("Close")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(L10n.t("Choose Destination…")) {
                    model.presentExportPanel(options: options)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.selectedPhoto == nil || model.isExporting || !format.isSupported() || collisionPolicy == .ask)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var formatPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(L10n.t("Format"), selection: $format) {
                ForEach(ExportFormat.allCases, id: \.self) { candidate in
                    Text(formatLabel(candidate)).tag(candidate)
                }
            }
            if !format.isSupported() {
                Text(L10n.t("This Mac can't export this format."))
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func formatLabel(_ candidate: ExportFormat) -> String {
        candidate.isSupported() ? candidate.displayName : "\(candidate.displayName) (\(L10n.t("Not Supported")))"
    }

    private var qualitySlider: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L10n.t("Quality"))
                Spacer()
                Text(verbatim: "\(Int((quality * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $quality, in: 0.4...1.0)
        }
    }

    private var bitDepthPicker: some View {
        Picker(L10n.t("Bit Depth"), selection: $bitDepth) {
            ForEach(ExportBitDepth.allCases, id: \.self) { candidate in
                Text(candidate.displayName).tag(candidate)
            }
        }
        .pickerStyle(.segmented)
    }

    private var resizeFields: some View {
        HStack {
            LabeledContent(L10n.t("Max Width")) {
                TextField(L10n.t("No limit"), text: $maximumWidthText)
                    .frame(width: 90)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent(L10n.t("Max Height")) {
                TextField(L10n.t("No limit"), text: $maximumHeightText)
                    .frame(width: 90)
                    .multilineTextAlignment(.trailing)
            }
        }
        .font(.caption)
    }

    private var dpiField: some View {
        LabeledContent(L10n.t("DPI")) {
            TextField(L10n.t("Default"), text: $dpiText)
                .frame(width: 90)
                .multilineTextAlignment(.trailing)
        }
        .font(.caption)
    }

    private var exifPolicyPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(L10n.t("EXIF"), selection: $exifRetentionPolicy) {
                ForEach(ExifRetentionPolicy.allCases, id: \.self) { candidate in
                    Text(candidate.displayName).tag(candidate)
                }
            }
            Text(L10n.t("Your RAW original was not changed."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var namingPicker: some View {
        Picker(L10n.t("Rename"), selection: $namingTemplate) {
            ForEach(ExportNamingTemplate.allCases, id: \.self) { candidate in
                Text(candidate.displayName).tag(candidate)
            }
        }
    }

    private var collisionPolicyPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(L10n.t("If a File Exists"), selection: $collisionPolicy) {
                ForEach(ExportCollisionPolicy.allCases, id: \.self) { candidate in
                    Text(collisionPolicyLabel(candidate)).tag(candidate)
                }
            }
            if collisionPolicy == .ask {
                Text(L10n.t("Asking before each export isn't supported yet."))
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func collisionPolicyLabel(_ candidate: ExportCollisionPolicy) -> String {
        candidate == .ask ? "\(candidate.displayName) (\(L10n.t("Not Supported")))" : candidate.displayName
    }

    private var watermarkSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(L10n.t("Add Watermark"), isOn: $watermarkEnabled)
            if watermarkEnabled {
                TextField(L10n.t("Watermark Text"), text: $watermarkText)
                Picker(L10n.t("Position"), selection: $watermarkPosition) {
                    ForEach(Watermark.Position.allCases, id: \.self) { candidate in
                        Text(candidate.displayName).tag(candidate)
                    }
                }
                .pickerStyle(.segmented)
                HStack {
                    Text(L10n.t("Opacity"))
                    Slider(value: $watermarkOpacity, in: 0.1...1.0)
                }
                HStack {
                    Text(L10n.t("Watermark Size"))
                    Slider(value: $watermarkSizeFraction, in: 0.01...0.2)
                }
            }
        }
        .font(.caption)
    }

    private func sizeDescription(_ width: Int, _ height: Int) -> String {
        guard width > 0, height > 0 else { return L10n.t("Unknown") }
        let megapixels = Double(width * height) / 1_000_000
        return String(format: "%d × %d (%.1f MP)", width, height, megapixels)
    }
}
