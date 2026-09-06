import SwiftUI
import Localization
import RawProcessingCore

/// Phase 5 Task 5.1: same format/quality/size/DPI/EXIF choices `ExportSheet`
/// collects for a single photo, applied to every photo in
/// `model.selectedPhotoIDs` at once, with live per-file pending/running/
/// succeeded/failed/cancelled status and a running total -- design spec
/// §8.3: "batch action affected N selected photos"; "failed / skipped / not
/// run 不得偽裝成成功".
struct BatchExportSheet: View {
    @EnvironmentObject private var model: LibraryViewModel

    @AppStorage("export.format") private var format: ExportFormat = .jpeg
    @AppStorage("export.quality") private var quality = 0.9
    @AppStorage("export.bitDepth") private var bitDepth: ExportBitDepth = .eightBit
    @AppStorage("export.exifRetentionPolicy") private var exifRetentionPolicy: ExifRetentionPolicy = .preserveAll
    @State private var maximumWidthText = ""
    @State private var maximumHeightText = ""
    @State private var dpiText = ""

    private var maximumWidth: Int? { Int(maximumWidthText) }
    private var maximumHeight: Int? { Int(maximumHeightText) }
    private var dpi: Double? { Double(dpiText) }

    private var options: MacExportOptions {
        MacExportOptions(
            format: format,
            quality: quality,
            bitDepth: bitDepth,
            maximumWidth: maximumWidth,
            maximumHeight: maximumHeight,
            dpi: dpi,
            exifRetentionPolicy: exifRetentionPolicy
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.t("Export Photos"))
                .font(.title3.weight(.semibold))

            Text(selectionCountLabel)
                .font(.callout)
                .foregroundStyle(.secondary)

            if model.batchExportItems.isEmpty {
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
            } else {
                progressList
                Divider()
                summaryLine
            }

            Divider()

            HStack {
                Button(L10n.t("Close")) {
                    model.closeBatchExportSheet()
                }
                .keyboardShortcut(.cancelAction)

                if model.isBatchExporting {
                    Button(L10n.t("Cancel")) {
                        model.cancelBatchExport()
                    }
                }

                Spacer()

                if model.batchExportItems.isEmpty {
                    Button(L10n.t("Choose Destination…")) {
                        model.presentBatchExportPanel(options: options)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.selectedPhotoIDs.isEmpty || !format.isSupported())
                }
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var selectionCountLabel: String {
        let count = model.batchExportItems.isEmpty ? model.selectedPhotoIDs.count : model.batchExportItems.count
        return count == 1
            ? L10n.t("1 photo selected")
            : "\(count) " + L10n.t("photos selected")
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

    private var progressList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.batchExportItems, id: \.id) { item in
                    HStack(spacing: 8) {
                        statusIcon(for: item.status)
                        Text(item.request.baseFilename)
                        Spacer()
                        Text(statusLabel(for: item.status))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
        }
        .frame(maxHeight: 240)
    }

    @ViewBuilder
    private func statusIcon(for status: BatchExportItemStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle.dotted")
                .foregroundStyle(.secondary)
        case .running:
            ProgressView()
                .controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "slash.circle")
                .foregroundStyle(.secondary)
        }
    }

    private func statusLabel(for status: BatchExportItemStatus) -> String {
        switch status {
        case .pending:
            return L10n.t("Waiting")
        case .running:
            return L10n.t("Exporting") + "…"
        case .succeeded:
            return L10n.t("Done")
        case .failed(let message):
            return message
        case .cancelled:
            return L10n.t("Cancelled")
        }
    }

    private var summaryLine: some View {
        let succeeded = model.batchExportItems.filter { if case .succeeded = $0.status { return true }; return false }.count
        let failed = model.batchExportItems.filter { if case .failed = $0.status { return true }; return false }.count
        let cancelled = model.batchExportItems.filter { $0.status == .cancelled }.count

        var parts: [String] = ["\(succeeded) \(L10n.t("succeeded"))"]
        if failed > 0 {
            parts.append("\(failed) \(L10n.t("failed to export"))")
        }
        if cancelled > 0 {
            parts.append("\(cancelled) \(L10n.t("cancelled"))")
        }
        return Text(parts.joined(separator: ", "))
            .font(.callout)
    }
}
