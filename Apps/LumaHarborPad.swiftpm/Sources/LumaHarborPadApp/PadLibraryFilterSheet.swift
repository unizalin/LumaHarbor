import EditorCore
import Localization
import PhotoLibraryCore
import SwiftUI

/// iPad's staged catalog filter editor. The sheet owns only temporary form
/// values; applying them calls LibraryBrowserSession.setCatalogFilters so the
/// same SQL-backed LibraryQuery contract powers every platform.
struct PadLibraryFilterSheet: View {
    @ObservedObject var library: PadLibraryModel
    @Environment(\.dismiss) private var dismiss

    @State private var ratingChoice = "any"
    @State private var flagChoice = "any"
    @State private var editedOnly = false
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
                Section(L10n.t("Rating")) {
                    Picker(L10n.t("Rating"), selection: $ratingChoice) {
                        Text(L10n.t("Any Rating")).tag("any")
                        Text(L10n.t("Unrated")).tag("unrated")
                        ForEach(1...5, id: \.self) { value in
                            Text("\(value)").tag("rating-\(value)")
                        }
                    }
                }

                Section(L10n.t("Flag")) {
                    Picker(L10n.t("Flag"), selection: $flagChoice) {
                        Text(L10n.t("Any Flag")).tag("any")
                        Text(L10n.t("Pick")).tag("pick")
                        Text(L10n.t("Reject")).tag("reject")
                        Text(L10n.t("No Flag")).tag("none")
                    }
                }

                Section(L10n.t("File facts")) {
                    Toggle(L10n.t("Edited"), isOn: $editedOnly)
                    TextField(L10n.t("Format"), text: $format)
                    TextField(L10n.t("Camera"), text: $camera)
                    TextField(L10n.t("Lens"), text: $lens)
                }

                Section(L10n.t("Keywords")) {
                    TextField(L10n.t("Keyword"), text: $keyword)
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
            .navigationTitle(L10n.t("Advanced Filters"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Cancel")) { dismiss() }
                        .frame(minWidth: 44, minHeight: 44)
                }
                ToolbarItem(placement: .automatic) {
                    Button(L10n.t("Clear")) {
                        library.clearCatalogFilters()
                        dismiss()
                    }
                    .frame(minWidth: 44, minHeight: 44)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("Apply")) {
                        apply()
                        dismiss()
                    }
                    .frame(minWidth: 44, minHeight: 44)
                }
            }
            .onAppear(perform: loadCurrentValues)
        }
    }

    private func loadCurrentValues() {
        switch library.ratingFilter {
        case .none: ratingChoice = "any"
        case .unrated: ratingChoice = "unrated"
        case .exact(let value): ratingChoice = "rating-\(value)"
        }

        switch library.flagFilter {
        case nil: flagChoice = "any"
        case .some(.pick): flagChoice = "pick"
        case .some(.reject): flagChoice = "reject"
        case .some(.none): flagChoice = "none"
        }

        editedOnly = library.hasEditsFilter == true
        format = library.formatFilter ?? ""
        camera = library.cameraFilter ?? ""
        lens = library.lensFilter ?? ""
        keyword = library.keywordFilter ?? ""
        limitsDateRange = library.captureDateFilter != nil
        startDate = library.captureDateFilter?.start ?? startDate
        endDate = library.captureDateFilter?.end ?? endDate
    }

    private func apply() {
        let rating: PhotoRatingFilter?
        switch ratingChoice {
        case "unrated": rating = .unrated
        case let value where value.hasPrefix("rating-"):
            rating = Int(value.dropFirst("rating-".count)).map(PhotoRatingFilter.exact)
        default: rating = nil
        }

        let flag: PhotoFlag?
        switch flagChoice {
        case "pick": flag = .pick
        case "reject": flag = .reject
        case "none": flag = PhotoFlag.none
        default: flag = nil
        }

        let captureDate = limitsDateRange
            ? PhotoDateRange(start: min(startDate, endDate), end: max(startDate, endDate))
            : nil

        library.setCatalogFilters(
            rating: rating,
            flag: flag,
            hasEdits: editedOnly ? true : nil,
            format: trimmedOrNil(format),
            camera: trimmedOrNil(camera),
            lens: trimmedOrNil(lens),
            captureDate: captureDate,
            keyword: trimmedOrNil(keyword)
        )
    }

    private func trimmedOrNil(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
