import Localization
import SwiftUI

/// Discrete cache-budget choices for the iPad's thumbnail disk cache (Task
/// 7 Step 5, global constraint: "512 MiB through 10 GiB configurable
/// range"). `.gib2` matches `PadAppServices.defaultThumbnailCacheByteBudget`
/// exactly, and is also the fallback whenever a persisted value is absent
/// or isn't one of these five exact byte counts -- never an unclamped
/// arbitrary budget.
enum PadThumbnailCacheBudget: Int64, CaseIterable, Identifiable {
    case mib512 = 536_870_912 // 512 MiB
    case gib1 = 1_073_741_824 // 1 GiB
    case gib2 = 2_147_483_648 // 2 GiB
    case gib5 = 5_368_709_120 // 5 GiB
    case gib10 = 10_737_418_240 // 10 GiB

    var id: Int64 { rawValue }

    static let `default`: PadThumbnailCacheBudget = .gib2

    static let userDefaultsKey = "PadLibraryThumbnailCacheByteBudget"

    var displayName: String {
        switch self {
        case .mib512: return L10n.t("512 MB")
        case .gib1: return L10n.t("1 GB")
        case .gib2: return L10n.t("2 GB")
        case .gib5: return L10n.t("5 GB")
        case .gib10: return L10n.t("10 GB")
        }
    }

    /// Reads whatever byte count is persisted under `userDefaultsKey` and
    /// resolves it to one of the five approved choices -- an absent key
    /// (`UserDefaults.integer(forKey:)` returns `0` when nothing is
    /// stored), a stale value from a wider range a future build once
    /// offered, or plain corruption all resolve to `.default` rather than
    /// an arbitrary unclamped budget. `userDefaults` is an injectable
    /// dependency (default `.standard`), mirroring
    /// `PhotoDocumentEditor`'s own `userDefaults: UserDefaults = .standard`
    /// convention, so a caller can substitute a scratch suite.
    static func resolvingPersisted(_ userDefaults: UserDefaults) -> PadThumbnailCacheBudget {
        let stored = Int64(userDefaults.integer(forKey: userDefaultsKey))
        return PadThumbnailCacheBudget(rawValue: stored) ?? .default
    }
}

/// The iPad's thumbnail cache-budget settings screen (Task 7 Step 5):
/// five discrete choices, persisted in `UserDefaults`, applied to the live
/// `ThumbnailProvider` immediately via its `setByteBudget(_:)` passthrough
/// -- never touching the Mac app's own `CacheBudget` constants
/// (`Sources/LumaHarborApp/AppServices.swift`), which this file never
/// imports or references.
struct PadLibrarySettingsView: View {
    let services: PadAppServices
    let userDefaults: UserDefaults

    @State private var selection: PadThumbnailCacheBudget

    init(services: PadAppServices, userDefaults: UserDefaults = .standard) {
        self.services = services
        self.userDefaults = userDefaults
        _selection = State(initialValue: PadThumbnailCacheBudget.resolvingPersisted(userDefaults))
    }

    var body: some View {
        Form {
            Section {
                ForEach(PadThumbnailCacheBudget.allCases) { budget in
                    Button {
                        selection = budget
                        apply(budget)
                    } label: {
                        HStack {
                            Text(budget.displayName)
                            Spacer()
                            // Never rely on the checkmark's color alone --
                            // its presence/absence is itself the signal.
                            if selection == budget {
                                Image(systemName: "checkmark")
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .accessibilityAddTraits(selection == budget ? [.isSelected] : [])
                }
            } footer: {
                Text(L10n.t("A larger cache keeps more thumbnails available offline, but uses more storage."))
            }
        }
        .navigationTitle(L10n.t("Thumbnail Cache"))
    }

    /// Persists `budget`, then calls the existing `ThumbnailProvider
    /// .setByteBudget(_:)` passthrough immediately -- the disk cache
    /// evicts down to the new budget right away rather than waiting for
    /// the next launch.
    private func apply(_ budget: PadThumbnailCacheBudget) {
        userDefaults.set(Int(budget.rawValue), forKey: PadThumbnailCacheBudget.userDefaultsKey)
        Task {
            try? await services.thumbnailProvider.setByteBudget(budget.rawValue)
        }
    }
}
