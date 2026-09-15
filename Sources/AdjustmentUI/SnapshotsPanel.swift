import EditorCore
import Localization
import PhotoLibraryCore
import RawProcessingCore
import SwiftUI

/// Snapshots and professional review panel (spec §6.6, §7.4).
/// Provides snapshot creation, deletion, renaming, duplicate, restore (compound undo),
/// and controls for highlight/shadow clipping, gamut warnings, and soft proofing.
public struct SnapshotsPanel: View {
    @ObservedObject public var editor: EditorSession
    @State private var newSnapshotName: String = ""
    @State private var editingSnapshotID: UUID?
    @State private var renamingText: String = ""

    public init(editor: EditorSession) {
        self.editor = editor
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // MARK: - Professional Preview Overlays
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.t("Professional Preview"))
                    .font(.headline)

                previewToggleRow
                softProofRow
            }
            .padding(10)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)

            Divider()

            // MARK: - Snapshots List & Management
            HStack {
                Text(L10n.t("Snapshots"))
                    .font(.headline)
                Spacer()
                Button {
                    editor.createSnapshot(name: "")
                } label: {
                    Label(L10n.t("Create Snapshot"), systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .help(L10n.t("Create Snapshot"))
            }

            if let activeComp = editor.comparisonSnapshot {
                comparisonBanner(activeComp)
            }

            if editor.snapshots.isEmpty {
                Text(L10n.t("No snapshots saved yet"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ForEach(editor.snapshots) { snapshot in
                    snapshotRow(snapshot)
                }
            }
        }
        .padding(8)
    }

    private func snapshotRow(_ snapshot: EditSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if editingSnapshotID == snapshot.id {
                    TextField("", text: $renamingText, onCommit: {
                        editor.renameSnapshot(id: snapshot.id, newName: renamingText)
                        editingSnapshotID = nil
                    })
                    .textFieldStyle(.roundedBorder)

                    Button(L10n.t("Done")) {
                        editor.renameSnapshot(id: snapshot.id, newName: renamingText)
                        editingSnapshotID = nil
                    }
                    .buttonStyle(.borderless)
                } else {
                    Text(snapshot.name)
                        .font(.body.weight(.medium))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)

                    Spacer()

                    Menu {
                        Button(L10n.t("Restore Snapshot")) {
                            editor.restoreSnapshot(id: snapshot.id)
                        }

                        Button(editor.comparisonSnapshot?.id == snapshot.id ? L10n.t("Exit Compare") : L10n.t("Compare (A/B)")) {
                            if editor.comparisonSnapshot?.id == snapshot.id {
                                editor.setComparisonSnapshot(nil)
                            } else {
                                editor.setComparisonSnapshot(snapshot)
                            }
                        }

                        Button(L10n.t("Duplicate")) {
                            editor.duplicateSnapshot(id: snapshot.id)
                        }

                        Button(L10n.t("Rename")) {
                            renamingText = snapshot.name
                            editingSnapshotID = snapshot.id
                        }

                        Divider()

                        Button(role: .destructive) {
                            editor.deleteSnapshot(id: snapshot.id)
                        } label: {
                            Text(L10n.t("Delete"))
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .frame(minWidth: 44, minHeight: 44)
                }
            }

            HStack {
                Text(snapshot.createdAt, style: .date)
                Text(snapshot.createdAt, style: .time)
                Spacer()
                Button(L10n.t("Restore")) {
                    editor.restoreSnapshot(id: snapshot.id)
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .foregroundStyle(.blue)
                .frame(minHeight: 44)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(editor.comparisonSnapshot?.id == snapshot.id ? Color.blue.opacity(0.08) : Color.primary.opacity(0.03))
        .cornerRadius(6)
    }

    private var previewToggleRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                highlightToggle
                shadowToggle
                gamutToggle
            }

            VStack(alignment: .leading, spacing: 8) {
                highlightToggle
                shadowToggle
                gamutToggle
            }
        }
    }

    private var highlightToggle: some View {
        Toggle(L10n.t("Highlights"), isOn: Binding(
            get: { editor.previewOptions.showHighlightClipping },
            set: { newValue in
                var opts = editor.previewOptions
                opts.showHighlightClipping = newValue
                editor.setPreviewOptions(opts)
            }
        ))
        #if os(macOS)
        .toggleStyle(.checkbox)
        #endif
        .frame(minHeight: 44)
    }

    private var shadowToggle: some View {
        Toggle(L10n.t("Shadows"), isOn: Binding(
            get: { editor.previewOptions.showShadowClipping },
            set: { newValue in
                var opts = editor.previewOptions
                opts.showShadowClipping = newValue
                editor.setPreviewOptions(opts)
            }
        ))
        #if os(macOS)
        .toggleStyle(.checkbox)
        #endif
        .frame(minHeight: 44)
    }

    private var gamutToggle: some View {
        Toggle(L10n.t("Gamut Warning"), isOn: Binding(
            get: { editor.previewOptions.showGamutWarning },
            set: { newValue in
                var opts = editor.previewOptions
                opts.showGamutWarning = newValue
                editor.setPreviewOptions(opts)
            }
        ))
        #if os(macOS)
        .toggleStyle(.checkbox)
        #endif
        .frame(minHeight: 44)
    }

    private var softProofRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Text(L10n.t("Soft Proof"))
                    .font(.caption)
                Spacer(minLength: 8)
                softProofPicker
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("Soft Proof"))
                    .font(.caption)
                softProofPicker
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var softProofPicker: some View {
        Picker("", selection: Binding(
            get: { editor.previewOptions.softProofProfile?.rawValue ?? "None" },
            set: { newValue in
                var opts = editor.previewOptions
                if newValue == "None" {
                    opts.softProofProfile = nil
                } else {
                    opts.softProofProfile = SoftProofProfile(rawValue: newValue)
                }
                editor.setPreviewOptions(opts)
            }
        )) {
            Text(L10n.t("None")).tag("None")
            ForEach(SoftProofProfile.allCases, id: \.self) { profile in
                Text(profile.rawValue).tag(profile.rawValue)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(minHeight: 44)
    }

    private func comparisonBanner(_ snapshot: EditSnapshot) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                comparisonLabel(snapshot)
                Spacer(minLength: 8)
                exitCompareButton
            }

            VStack(alignment: .leading, spacing: 4) {
                comparisonLabel(snapshot)
                exitCompareButton
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(6)
        .background(Color.blue.opacity(0.1))
        .cornerRadius(6)
    }

    private func comparisonLabel(_ snapshot: EditSnapshot) -> some View {
        Label(
            "\(L10n.t("Comparing with")): \(snapshot.name)",
            systemImage: "square.split.2x1"
        )
        .font(.caption)
        .foregroundStyle(.blue)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var exitCompareButton: some View {
        Button(L10n.t("Exit Compare")) {
            editor.setComparisonSnapshot(nil)
        }
        .font(.caption)
        .frame(minHeight: 44)
    }
}
