import AdjustmentUI
import EditorCore
import PhotoLibraryCore
import Localization
import SwiftUI

/// Right pane: the shared basic adjustments alongside Mac-only preset controls.
struct InspectorView: View {
    @EnvironmentObject private var model: LibraryViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let photo = model.editor.photo {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        MetadataPanel(snapshot: EditorMetadataSnapshot(photo: photo))
                        Divider()
                        PresetBrowserView()
                        Divider()
                        BasicAdjustmentPanel(editor: model.editor)
                    }
                    .padding(14)
                }
            } else {
                ContentUnavailableMessage()
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var header: some View {
        HStack {
            Text(L10n.t("Adjustments"))
                .font(.headline)
            Spacer()
            Button(L10n.t("Reset All")) {
                model.editor.resetAll()
            }
            .controlSize(.small)
            .disabled(model.editor.photo == nil || !model.editor.hasEdits)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// AwayPhotoRawEditor parity Phase 1 Task 1: the metadata/EXIF block (design
/// spec §6.2, §8.1). Every value comes from `EditorMetadataSnapshot`, which
/// already formats or nils out each field -- this view only lays the rows
/// out and labels them, so a missing EXIF field never crashes the panel and
/// nothing here ever reads a raw source URL.
private struct MetadataPanel: View {
    let snapshot: EditorMetadataSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.t("Metadata"))
                .font(.headline)
            row(L10n.t("Filename"), snapshot.filename)
            row(L10n.t("Format"), snapshot.formatDescription)
            row(L10n.t("Dimensions"), snapshot.pixelDimensions)
            row(L10n.t("File Size"), snapshot.fileSizeDescription)
            row(L10n.t("Camera"), snapshot.cameraDescription)
            row(L10n.t("Lens"), snapshot.lensDescription)
            row(L10n.t("Focal Length"), snapshot.focalLengthDescription)
            row(L10n.t("Aperture"), snapshot.apertureDescription)
            row(L10n.t("Shutter Speed"), snapshot.shutterSpeedDescription)
            row(L10n.t("ISO"), snapshot.isoDescription)
            row(L10n.t("Capture Date"), snapshot.captureDateDescription)
            row(L10n.t("Orientation"), snapshot.orientationDescription)
        }
    }

    private func row(_ label: String, _ value: String?) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value ?? "—")
        }
        .font(.caption)
    }
}

private struct ContentUnavailableMessage: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text(L10n.t("Select a photo to start editing"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
