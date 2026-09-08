import AdjustmentUI
import EditorCore
import PhotoLibraryCore
import Localization
import RawProcessingCore
import SwiftUI

/// Right pane: the shared basic adjustments alongside Mac-only preset controls.
struct InspectorView: View {
    @EnvironmentObject private var model: LibraryViewModel
    @State private var selectedTab: InspectorTab = .adjustments
    @State private var expandedGroups: Set<InspectorGroup> = [.basic, .color]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Picker("", selection: $selectedTab) {
                ForEach(InspectorTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            if model.editor.photo == nil {
                ContentUnavailableMessage()
            } else {
                switch selectedTab {
                case .adjustments:
                    adjustmentContent
                case .presets:
                    PresetBrowserView()
                case .metadata:
                    metadataContent
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var adjustmentContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HistogramPanel(histogram: model.editor.histogram)
                inspectorGroup(.basic, title: L10n.t("Basic")) {
                    BasicAdjustmentPanel(editor: model.editor, kinds: MacBasicAdjustmentPanel.toneKinds)
                }
                inspectorGroup(.color, title: L10n.t("Color")) {
                    HStack {
                        Text(L10n.t("White Balance")).font(.headline)
                        Spacer()
                        WhiteBalanceEyedropperButton(editor: model.editor)
                    }
                    BasicAdjustmentPanel(editor: model.editor, kinds: MacBasicAdjustmentPanel.whiteBalanceKinds)
                    ColorAdjustmentPanel(editor: model.editor)
                }
                inspectorGroup(.curve, title: L10n.t("Curve")) {
                    CurveAdjustmentPanel(editor: model.editor)
                }
                inspectorGroup(.detail, title: L10n.t("Detail")) {
                    DetailAdjustmentPanel(editor: model.editor)
                }
                inspectorGroup(.effects, title: L10n.t("Effects")) {
                    EffectsAdjustmentPanel(editor: model.editor)
                }
                inspectorGroup(.geometry, title: L10n.t("Geometry")) {
                    GeometryAdjustmentPanel(editor: model.editor)
                }
                inspectorGroup(.local, title: L10n.t("Local Adjustments")) {
                    LocalAdjustmentsPanel(editor: model.editor)
                }
            }
            .padding(14)
        }
    }

    private var metadataContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let photo = model.editor.photo {
                    MetadataPanel(snapshot: EditorMetadataSnapshot(photo: photo))
                }
                Divider()
                SaveStatePanel(state: model.editor.saveState)
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private func inspectorGroup<Content: View>(
        _ group: InspectorGroup,
        title: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { expandedGroups.contains(group) },
                set: { isExpanded in
                    if isExpanded {
                        expandedGroups.insert(group)
                    } else {
                        expandedGroups.remove(group)
                    }
                }
            )
        ) {
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(.top, 8)
        } label: {
            Text(title).font(.headline)
        }
    }

    private var header: some View {
        HStack {
            Text(L10n.t("Adjustments"))
                .font(.headline)
            Spacer()
            adjustmentActionsMenu
            Button(L10n.t("Reset All")) {
                model.editor.resetAll()
            }
            .controlSize(.small)
            .disabled(selectedTab != .adjustments || model.editor.photo == nil || !model.editor.hasEdits)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Phase 2.2 (spec §6.2): "Copy Adjustments" / "Paste Adjustments" /
    /// "Sync to Selected Photos", plus the two opt-in toggles that decide
    /// whether the *next* copy also captures Geometry/Local Adjustments
    /// (off by default -- global adjustments are always copied).
    private var adjustmentActionsMenu: some View {
        Menu {
            Toggle(L10n.t("Include Geometry"), isOn: $model.copyIncludesGeometry)
            Toggle(L10n.t("Include Local Adjustments"), isOn: $model.copyIncludesLocalAdjustments)
            Divider()
            Button(L10n.t("Copy Adjustments")) {
                model.copyAdjustments()
            }
            .disabled(model.editor.photo == nil)
            Button(L10n.t("Paste Adjustments")) {
                model.pasteAdjustments()
            }
            .disabled(model.editor.photo == nil || model.adjustmentClipboard == nil)
            Button(L10n.t("Sync to Selected Photos")) {
                Task { await model.syncAdjustmentsToSelectedPhotos() }
            }
            .disabled(model.adjustmentClipboard == nil || model.selectedPhotoIDs.count <= 1)
        } label: {
            Label(L10n.t("Adjustments Actions"), systemImage: "doc.on.doc")
        }
        .controlSize(.small)
        .disabled(selectedTab != .adjustments)
    }
}

private enum InspectorTab: String, CaseIterable, Identifiable {
    case adjustments
    case presets
    case metadata

    var id: String { rawValue }

    var title: String {
        switch self {
        case .adjustments: return L10n.t("Adjustments")
        case .presets: return L10n.t("Presets")
        case .metadata: return L10n.t("Metadata")
        }
    }
}

private enum InspectorGroup: Hashable {
    case basic, color, curve, detail, effects, geometry, local
}

private enum MacBasicAdjustmentPanel {
    static let toneKinds: [AdjustmentKind] = [
        .exposure, .contrast, .highlights, .shadows, .whites, .blacks, .vibrance, .saturation
    ]
    static let whiteBalanceKinds: [AdjustmentKind] = [.temperature, .tint]
}

private struct SaveStatePanel: View {
    let state: SaveState

    var body: some View {
        switch state {
        case .unchanged:
            Label(L10n.t("Saved"), systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .pending:
            Label(L10n.t("Unsaved"), systemImage: "circle.dotted")
                .foregroundStyle(.secondary)
        case .saving:
            Label(L10n.t("Saving…"), systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
        case .saved:
            Label(L10n.t("Saved"), systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label(L10n.t("Not saved"), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .help(message)
        }
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
