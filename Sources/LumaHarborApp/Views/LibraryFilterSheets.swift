import PhotoLibraryCore
import Localization
import SwiftUI

/// Advanced catalog filters kept out of the main toolbar so the grid remains
/// useful at compact window widths. Values are staged locally and only become
/// query state when the user taps Apply.
struct LibraryFilterSheet: View {
    @EnvironmentObject private var model: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var format = ""
    @State private var camera = ""
    @State private var lens = ""
    @State private var keyword = ""
    @State private var limitsDateRange = false
    @State private var startDate = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var endDate = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.t("File facts")) {
                    TextField(L10n.t("Format"), text: $format)
                    TextField(L10n.t("Camera"), text: $camera)
                    TextField(L10n.t("Lens"), text: $lens)
                }

                Section(L10n.t("Keywords")) {
                    TextField(L10n.t("Keyword"), text: $keyword)
                        .textFieldStyle(.roundedBorder)
                    Text(L10n.t("Matches photos that contain this keyword."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(L10n.t("Capture Date")) {
                    Toggle(L10n.t("Limit by capture date"), isOn: $limitsDateRange)
                    if limitsDateRange {
                        DatePicker(L10n.t("From"), selection: $startDate, displayedComponents: [.date])
                        DatePicker(L10n.t("To"), selection: $endDate, displayedComponents: [.date])
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(L10n.t("Advanced Filters"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .automatic) {
                    Button(L10n.t("Clear")) {
                        model.clearCatalogFilters()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("Apply")) {
                        apply()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .onAppear(perform: loadCurrentValues)
        }
        .frame(minWidth: 390, minHeight: 360)
    }

    private func loadCurrentValues() {
        format = model.formatFilter ?? ""
        camera = model.cameraFilter ?? ""
        lens = model.lensFilter ?? ""
        keyword = model.keywordFilter ?? ""
        limitsDateRange = model.captureDateStartFilter != nil || model.captureDateEndFilter != nil
        startDate = model.captureDateStartFilter ?? startDate
        endDate = model.captureDateEndFilter ?? endDate
    }

    private func apply() {
        model.formatFilter = trimmedOrNil(format)
        model.cameraFilter = trimmedOrNil(camera)
        model.lensFilter = trimmedOrNil(lens)
        model.keywordFilter = trimmedOrNil(keyword)

        guard limitsDateRange else {
            model.captureDateStartFilter = nil
            model.captureDateEndFilter = nil
            return
        }

        let lower = min(startDate, endDate)
        let upper = max(startDate, endDate)
        model.captureDateStartFilter = Calendar.current.startOfDay(for: lower)
        model.captureDateEndFilter = Calendar.current.date(
            bySettingHour: 23,
            minute: 59,
            second: 59,
            of: upper
        ) ?? upper
    }

    private func trimmedOrNil(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Edits the complete keyword set for one photo. The index store remains the
/// single source of truth; this view only turns the compact text representation
/// into individual user inputs.
struct PhotoKeywordEditorSheet: View {
    let photo: PhotoAsset
    let onSave: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(photo: PhotoAsset, onSave: @escaping ([String]) -> Void) {
        self.photo = photo
        self.onSave = onSave
        _text = State(initialValue: photo.keywords.map(\.displayValue).joined(separator: ", "))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.t("Keywords")) {
                    TextEditor(text: $text)
                        .frame(minHeight: 90)
                    Text(L10n.t("Separate keywords with commas or new lines."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(L10n.t("Edit Keywords"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("Save")) {
                        onSave(parseKeywords(text))
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(minWidth: 360, minHeight: 260)
    }

    private func parseKeywords(_ value: String) -> [String] {
        value.components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
