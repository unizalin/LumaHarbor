import AdjustmentUI
import EditorCore
import Localization
import PhotoLibraryCore
import RawProcessingCore
import SwiftUI

// MARK: - Info panel helpers

/// RGB histogram block for the Info domain. Renders the current rendered-preview
/// histogram; shows a localized fallback while histogram is nil (still computing).
struct PadHistogramBlock: View {
    let histogram: HistogramData?

    var body: some View {
        HistogramPanel(histogram: histogram)
    }
}

/// Displays the current EditorSession save state in the Info domain.
struct PadSaveStateBlock: View {
    let saveState: SaveState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.t("Save State"))
                .font(.subheadline.weight(.semibold))
            switch saveState {
            case .unchanged, .saved:
                Label(L10n.t("Saved"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            case .pending:
                Label(L10n.t("Unsaved changes"), systemImage: "clock")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            case .saving:
                Label(L10n.t("Saving…"), systemImage: "arrow.clockwise")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            case .failed(let message):
                Label(L10n.t("Save failed"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Displays safe EditorMetadataSnapshot fields (no path, bookmark, or signing info).
struct PadMetadataBlock: View {
    let snapshot: EditorMetadataSnapshot
    let photo: PhotoAsset
    @ObservedObject var batchCoordinator: PadBatchAdjustmentCoordinator
    let recipe: ResolvedRawRenderRecipe?

    @State private var keywordText: String
    @State private var isSavingKeywords = false
    @State private var message: String?

    init(
        snapshot: EditorMetadataSnapshot,
        photo: PhotoAsset,
        batchCoordinator: PadBatchAdjustmentCoordinator,
        recipe: ResolvedRawRenderRecipe?
    ) {
        self.snapshot = snapshot
        self.photo = photo
        self.batchCoordinator = batchCoordinator
        self.recipe = recipe
        _keywordText = State(initialValue: photo.keywords.map(\.displayValue).joined(separator: ", "))
    }

    private struct Row: View {
        let label: String
        let value: String

        var body: some View {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 8) {
                    labelView
                        .frame(width: 96, alignment: .leading)
                    valueView
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 2) {
                    labelView
                    valueView
                }
            }
        }

        private var labelView: some View {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        private var valueView: some View {
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("File Info"))
                .font(.subheadline.weight(.semibold))
            Row(label: L10n.t("Filename"), value: snapshot.filename)
            Row(label: L10n.t("Format"), value: snapshot.formatDescription)
            if let v = snapshot.pixelDimensions   { Row(label: L10n.t("Dimensions"),   value: v) }
            if let v = snapshot.fileSizeDescription { Row(label: L10n.t("File Size"),   value: v) }
            if let v = snapshot.cameraDescription  { Row(label: L10n.t("Camera"),       value: v) }
            if let v = snapshot.lensDescription    { Row(label: L10n.t("Lens"),         value: v) }
            if let v = snapshot.focalLengthDescription { Row(label: L10n.t("Focal Length"), value: v) }
            if let v = snapshot.apertureDescription  { Row(label: L10n.t("Aperture"),   value: v) }
            if let v = snapshot.shutterSpeedDescription { Row(label: L10n.t("Shutter"), value: v) }
            if let v = snapshot.isoDescription       { Row(label: L10n.t("ISO"),        value: v) }
            if let v = snapshot.captureDateDescription { Row(label: L10n.t("Date"),     value: v) }
            if let v = snapshot.orientationDescription { Row(label: L10n.t("Orientation"), value: v) }

            RawRenderDiagnosticsPanel(recipe: recipe)

            Divider()
            Text(L10n.t("Curation"))
                .font(.subheadline.weight(.semibold))
            ratingControls
            flagControl
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.t("Keywords"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                keywordEditor
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .onChange(of: photo.id) { _, _ in
            keywordText = photo.keywords.map(\.displayValue).joined(separator: ", ")
        }
    }

    private var keywordEditor: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                keywordField
                saveKeywordsButton
            }

            VStack(alignment: .leading, spacing: 6) {
                keywordField
                HStack {
                    Spacer(minLength: 0)
                    saveKeywordsButton
                }
            }
        }
    }

    private var keywordField: some View {
        TextField(L10n.t("Keyword"), text: $keywordText)
            .textFieldStyle(.roundedBorder)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
    }

    private var saveKeywordsButton: some View {
        Button {
            saveKeywords()
        } label: {
            if isSavingKeywords {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "checkmark")
            }
        }
        .buttonStyle(.borderedProminent)
        .frame(minWidth: 44, minHeight: 44)
        .disabled(isSavingKeywords)
        .accessibilityLabel(Text(L10n.t("Save Keywords")))
    }

    private var ratingControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                ratingLabel
                    .frame(width: 96, alignment: .leading)
                ratingButtons
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 4) {
                ratingLabel
                ratingButtons
            }
        }
    }

    private var ratingLabel: some View {
        Text(L10n.t("Rating"))
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var ratingButtons: some View {
        HStack(spacing: 0) {
            ForEach(0...5, id: \.self) { value in
                Button {
                    Task {
                        let succeeded = await batchCoordinator.setRating(value, for: photo.id)
                        if !succeeded { message = L10n.t("Couldn't save rating") }
                    }
                } label: {
                    Image(systemName: value == 0 ? "xmark.circle" : "star.fill")
                        .foregroundStyle(value > photo.rating ? Color.secondary : Color.yellow)
                }
                .buttonStyle(.plain)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel(Text("\(L10n.t("Rating")) \(value)"))
            }
        }
    }

    private var flagControl: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                flagLabel
                    .frame(width: 96, alignment: .leading)
                flagMenu
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 4) {
                flagLabel
                flagMenu
            }
        }
    }

    private var flagLabel: some View {
        Text(L10n.t("Flag"))
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var flagMenu: some View {
        Menu {
            ForEach(PhotoFlag.allCases, id: \.self) { flag in
                Button {
                    Task {
                        let succeeded = await batchCoordinator.setFlag(flag, for: photo.id)
                        if !succeeded { message = L10n.t("Couldn't save flag") }
                    }
                } label: {
                    Label(flagTitle(flag), systemImage: photo.flag == flag ? "checkmark" : "")
                }
            }
        } label: {
            Label(flagTitle(photo.flag), systemImage: flagSymbol(photo.flag))
        }
        .frame(minWidth: 44, minHeight: 44)
    }

    private func saveKeywords() {
        isSavingKeywords = true
        let inputs = keywordText
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        Task {
            let succeeded = await batchCoordinator.setKeywords(inputs, for: photo.id)
            isSavingKeywords = false
            if !succeeded {
                message = L10n.t("Couldn't save keywords")
            } else {
                message = nil
                keywordText = inputs.joined(separator: ", ")
            }
        }
    }

    private func flagTitle(_ flag: PhotoFlag) -> String {
        switch flag {
        case .none: return L10n.t("None")
        case .pick: return L10n.t("Pick")
        case .reject: return L10n.t("Reject")
        }
    }

    private func flagSymbol(_ flag: PhotoFlag) -> String {
        switch flag {
        case .none: return "flag"
        case .pick: return "flag.fill"
        case .reject: return "flag.slash"
        }
    }
}
