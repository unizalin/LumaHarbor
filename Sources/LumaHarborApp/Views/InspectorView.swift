import AdjustmentUI
import EditorCore
import PhotoLibraryCore
import Localization
import RawProcessingCore
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
                        HistogramPanel(histogram: model.editor.histogram)
                        Divider()
                        MetadataPanel(snapshot: EditorMetadataSnapshot(photo: photo))
                        Divider()
                        PresetBrowserView()
                        Divider()
                        Text(L10n.t("Basic")).font(.headline)
                        BasicAdjustmentPanel(editor: model.editor)
                        Divider()
                        Text(L10n.t("Color")).font(.headline)
                        ColorAdjustmentPanel(editor: model.editor)
                        Divider()
                        Text(L10n.t("Curve")).font(.headline)
                        CurveAdjustmentPanel(editor: model.editor)
                        Divider()
                        Text(L10n.t("Detail")).font(.headline)
                        DetailAdjustmentPanel(editor: model.editor)
                        Divider()
                        Text(L10n.t("Effects")).font(.headline)
                        EffectsAdjustmentPanel(editor: model.editor)
                        Divider()
                        Text(L10n.t("Geometry")).font(.headline)
                        GeometryAdjustmentPanel(editor: model.editor)
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

/// AwayPhotoRawEditor parity Phase 1 Task 2: the histogram block (design
/// spec §6.2, §8.1). `histogram` comes straight from `EditorSession
/// .histogram`, which tracks the currently displayed *rendered* preview
/// frame, not the RAW file's own fixed statistics -- this view only draws
/// whatever it's handed and shows localized fallback text while there is
/// nothing to draw yet (no preview has rendered, or the last one failed).
private struct HistogramPanel: View {
    let histogram: HistogramData?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.t("Histogram"))
                .font(.headline)
            if let histogram {
                Canvas { context, size in
                    Self.draw(histogram.red, color: .red, in: context, size: size)
                    Self.draw(histogram.green, color: .green, in: context, size: size)
                    Self.draw(histogram.blue, color: .blue, in: context, size: size)
                }
                .frame(height: 80)
                .background(Color.black.opacity(0.05))
            } else {
                Text(L10n.t("No histogram available yet"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
                    .background(Color.black.opacity(0.05))
            }
        }
    }

    /// One channel's own filled curve over the composite's shared axes --
    /// three of these overlaid (one per channel) is the "RGB composite" the
    /// plan calls for, without a separate view per bin.
    private static func draw(_ bins: [Int], color: Color, in context: GraphicsContext, size: CGSize) {
        guard let maxCount = bins.max(), maxCount > 0 else { return }
        var path = Path()
        let stepX = size.width / CGFloat(bins.count)
        path.move(to: CGPoint(x: 0, y: size.height))
        for (index, count) in bins.enumerated() {
            let x = CGFloat(index) * stepX
            let normalized = CGFloat(count) / CGFloat(maxCount)
            let y = size.height - (normalized * size.height)
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        context.fill(path, with: .color(color.opacity(0.35)))
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
