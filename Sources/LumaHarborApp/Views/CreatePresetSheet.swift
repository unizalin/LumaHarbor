import Localization
import PresetCore
import RawProcessingCore
import SwiftUI

/// A checkable group of related `AdjustmentFieldID`s (spec §9.2's field
/// checklist). Grouped rather than one checkbox per leaf -- 48 individual
/// checkboxes would swamp the sheet -- but every group still maps onto a
/// spec-legible, exact set of fields, never a fuzzy "everything else" bucket.
private enum PresetFieldGroup: CaseIterable, Identifiable {
    case exposure, temperature, tint, contrast, highlights, shadows, whites, blacks, vibrance, saturation
    case toneCurve
    case hslRed, hslOrange, hslYellow, hslGreen, hslAqua, hslBlue, hslPurple, hslMagenta
    case splitToning, sharpening, noiseReduction, vignette, grain

    var id: Self { self }

    var fields: Set<AdjustmentFieldID> {
        switch self {
        case .exposure: return [.basicExposure]
        case .temperature: return [.basicTemperature]
        case .tint: return [.basicTint]
        case .contrast: return [.basicContrast]
        case .highlights: return [.basicHighlights]
        case .shadows: return [.basicShadows]
        case .whites: return [.basicWhites]
        case .blacks: return [.basicBlacks]
        case .vibrance: return [.basicVibrance]
        case .saturation: return [.basicSaturation]
        case .toneCurve: return [.advancedToneCurve]
        case .hslRed: return [.hslRedHue, .hslRedSaturation, .hslRedLuminance]
        case .hslOrange: return [.hslOrangeHue, .hslOrangeSaturation, .hslOrangeLuminance]
        case .hslYellow: return [.hslYellowHue, .hslYellowSaturation, .hslYellowLuminance]
        case .hslGreen: return [.hslGreenHue, .hslGreenSaturation, .hslGreenLuminance]
        case .hslAqua: return [.hslAquaHue, .hslAquaSaturation, .hslAquaLuminance]
        case .hslBlue: return [.hslBlueHue, .hslBlueSaturation, .hslBlueLuminance]
        case .hslPurple: return [.hslPurpleHue, .hslPurpleSaturation, .hslPurpleLuminance]
        case .hslMagenta: return [.hslMagentaHue, .hslMagentaSaturation, .hslMagentaLuminance]
        case .splitToning:
            return [.splitToningShadowHue, .splitToningShadowSaturation, .splitToningHighlightHue,
                    .splitToningHighlightSaturation, .splitToningBalance]
        case .sharpening:
            return [.sharpeningAmount, .sharpeningRadius, .sharpeningDetail, .sharpeningMasking]
        case .noiseReduction:
            return [.noiseReductionLuminanceAmount, .noiseReductionLuminanceDetail,
                    .noiseReductionColorAmount, .noiseReductionColorDetail]
        case .vignette: return [.vignetteAmount, .vignetteMidpoint, .vignetteRoundness, .vignetteFeather]
        case .grain: return [.grainAmount, .grainSize, .grainRoughness]
        }
    }

    var title: String {
        switch self {
        case .exposure: return L10n.t("Exposure")
        case .temperature: return L10n.t("Temperature")
        case .tint: return L10n.t("Tint")
        case .contrast: return L10n.t("Contrast")
        case .highlights: return L10n.t("Highlights")
        case .shadows: return L10n.t("Shadows")
        case .whites: return L10n.t("Whites")
        case .blacks: return L10n.t("Blacks")
        case .vibrance: return L10n.t("Vibrance")
        case .saturation: return L10n.t("Saturation")
        case .toneCurve: return L10n.t("Tone Curve")
        case .hslRed: return L10n.t("Red")
        case .hslOrange: return L10n.t("Orange")
        case .hslYellow: return L10n.t("Yellow")
        case .hslGreen: return L10n.t("Green")
        case .hslAqua: return L10n.t("Aqua")
        case .hslBlue: return L10n.t("Blue")
        case .hslPurple: return L10n.t("Purple")
        case .hslMagenta: return L10n.t("Magenta")
        case .splitToning: return L10n.t("Split Toning")
        case .sharpening: return L10n.t("Sharpening")
        case .noiseReduction: return L10n.t("Noise Reduction")
        case .vignette: return L10n.t("Vignette")
        case .grain: return L10n.t("Grain")
        }
    }
}

/// Spec §9.2: create a preset from the open photo. Defaults to whatever
/// currently differs from neutral; the user can also include a field that's
/// still at its default. Saving only writes the preset -- it never touches
/// the photo's own adjustments or Undo history.
struct CreatePresetSheet: View {
    @EnvironmentObject private var model: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var groupPathText = ""
    @State private var isFavorite = false
    @State private var scope: PresetScopeKind = .mine
    @State private var selectedFields: Set<AdjustmentFieldID> = []
    @State private var isSaving = false

    private var adjustments: PhotoAdjustments { model.editor.adjustments }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.t("Create Preset"))
                .font(.title3.weight(.semibold))

            TextField(L10n.t("Name"), text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(L10n.t("Preset name"))

            TextField(L10n.t("Group (optional, use / for nesting)"), text: $groupPathText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(L10n.t("Preset group"))

            HStack {
                Toggle(L10n.t("Favorite"), isOn: $isFavorite)
                Spacer()
                // The "This Library" segment only exists when there's a
                // library scope to save into -- rather than disabling the
                // whole picker after the fact (which used to trap `scope`
                // on `.library` with no way back to `.mine` once
                // `hasLibraryScope` was false), the invalid option is simply
                // never selectable in the first place.
                Picker(L10n.t("Save to"), selection: $scope) {
                    Text(PresetScopeKind.mine.title).tag(PresetScopeKind.mine)
                    if model.presetLibrary.hasLibraryScope {
                        Text(PresetScopeKind.library.title).tag(PresetScopeKind.library)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
            }

            Divider()

            Text(L10n.t("Include in this preset"))
                .font(.callout.weight(.semibold))

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(PresetFieldGroup.allCases) { group in
                        Toggle(group.title, isOn: binding(for: group))
                            .toggleStyle(.checkbox)
                    }
                }
            }
            .frame(height: 220)

            Text("\(L10n.t("Fields included:")) \(selectedFields.count)")
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
                        // Only dismiss on success. This used to dismiss
                        // unconditionally -- a save failure set `alert`
                        // (spec-correct) but the sheet was already gone by
                        // the time anything could have shown it, and
                        // `alert` wasn't bound to any View in the first
                        // place (round 2, finding #4). Staying open lets
                        // the `.alert` binding below actually present.
                        let saved = await model.presetLibrary.createPreset(
                            name: name,
                            groupPath: groupPathText
                                .split(separator: "/")
                                .map { $0.trimmingCharacters(in: .whitespaces) }
                                .filter { !$0.isEmpty },
                            isFavorite: isFavorite,
                            scope: scope,
                            selectedFields: selectedFields,
                            from: adjustments
                        )
                        isSaving = false
                        if saved { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                // Second line of defense alongside the picker above and
                // `createPreset`'s own guard: this must never be tappable
                // while pointed at a scope that doesn't actually exist.
                .disabled(
                    name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving
                        || (scope == .library && !model.presetLibrary.hasLibraryScope)
                )
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            selectedFields = AdjustmentPatch.modifiedFields(in: adjustments)
        }
        .onChange(of: model.presetLibrary.hasLibraryScope) { _, hasLibraryScope in
            // The library can close while this sheet is still open -- fall
            // back to a scope that's actually available rather than leaving
            // `scope` pointed at one that just disappeared.
            if !hasLibraryScope, scope == .library {
                scope = .mine
            }
        }
        // A save failure keeps this sheet open (see the Save button above)
        // specifically so this can present -- an `.alert` bound to the same
        // `presetLibrary.alert` on `PresetBrowserView` underneath would be
        // covered by this sheet and unable to show while it's up.
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
            get: { group.fields.isSubset(of: selectedFields) && !group.fields.isEmpty },
            set: { included in
                if included {
                    selectedFields.formUnion(group.fields)
                } else {
                    selectedFields.subtract(group.fields)
                }
            }
        )
    }
}
