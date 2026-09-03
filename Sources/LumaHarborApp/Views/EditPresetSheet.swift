import Localization
import PresetCore
import SwiftUI

/// Phase 3 Task 3.1: edit an already-saved preset's name, group, favorite,
/// and field membership. Unlike `CreatePresetSheet`, there is no open photo
/// to source a newly-checked field's value from, so this only ever *removes*
/// a field that's already in the preset's own patch -- never adds one that
/// isn't. Saving goes through `PresetLibraryViewModel.updatePreset`, which
/// keeps the same identity and `createdAt` (spec-consistent with rename's
/// own "檔名不是身份" rule) and drops any unchecked field via
/// `AdjustmentPatch.excluding(_:)`.
struct EditPresetSheet: View {
    @EnvironmentObject private var model: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    let item: PresetListItem

    @State private var name: String
    @State private var groupPathText: String
    @State private var isFavorite: Bool
    @State private var keptFields: Set<AdjustmentFieldID>
    @State private var isSaving = false

    init(item: PresetListItem) {
        self.item = item
        _name = State(initialValue: item.document.name)
        _groupPathText = State(initialValue: item.document.groupPath.joined(separator: "/"))
        _isFavorite = State(initialValue: item.document.isFavorite)
        _keptFields = State(initialValue: presentFields(in: item.document))
    }

    /// Only groups that have at least one field already present in the
    /// patch are shown -- offering a checkbox for a field the preset never
    /// set would look like "add this field" with no value to add.
    private var groups: [PresetFieldGroup] {
        let present = presentFields(in: item.document)
        return PresetFieldGroup.allCases.filter { !$0.fields.isDisjoint(with: present) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.t("Edit Preset"))
                .font(.title3.weight(.semibold))

            TextField(L10n.t("Name"), text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(L10n.t("Preset name"))

            TextField(L10n.t("Group (optional, use / for nesting)"), text: $groupPathText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(L10n.t("Preset group"))

            Toggle(L10n.t("Favorite"), isOn: $isFavorite)

            Divider()

            Text(L10n.t("Fields in this preset"))
                .font(.callout.weight(.semibold))
            Text(L10n.t("Uncheck a field to remove it from this preset. New fields can only be added by creating a preset from an open photo."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(groups) { group in
                        Toggle(group.title, isOn: binding(for: group))
                            .toggleStyle(.checkbox)
                    }
                }
            }
            .frame(height: 220)

            Text("\(L10n.t("Fields included:")) \(keptFields.count)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            HStack {
                Button(L10n.t("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.t("Save")) {
                    Task {
                        isSaving = true
                        let saved = await model.presetLibrary.updatePreset(
                            item,
                            name: name,
                            groupPath: groupPathText
                                .split(separator: "/")
                                .map { $0.trimmingCharacters(in: .whitespaces) }
                                .filter { !$0.isEmpty },
                            isFavorite: isFavorite,
                            keptFields: keptFields
                        )
                        isSaving = false
                        if saved { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
            }
        }
        .padding(20)
        .frame(width: 440)
        // Same reasoning as CreatePresetSheet's own binding: a save failure
        // keeps this sheet open (see the Save button above) specifically so
        // this can present, since PresetBrowserView's own alert binding to
        // the same `presetLibrary.alert` would be covered while this sheet
        // is up.
        .alert(item: Binding(
            get: { model.presetLibrary.alert },
            set: { model.presetLibrary.alert = $0 }
        )) { alert in
            Alert(
                title: Text(alert.title),
                message: Text([alert.message, alert.nextStep].compactMap { $0 }.joined(separator: "\n\n")),
                dismissButton: .default(Text(L10n.t("OK")))
            )
        }
    }

    private func binding(for group: PresetFieldGroup) -> Binding<Bool> {
        Binding(
            get: { group.fields.isSubset(of: keptFields) },
            set: { included in
                if included {
                    keptFields.formUnion(group.fields)
                } else {
                    keptFields.subtract(group.fields)
                }
            }
        )
    }
}

private func presentFields(in document: PresetDocument) -> Set<AdjustmentFieldID> {
    Set(AdjustmentFieldID.allCases.filter { document.patch.contains($0) })
}
