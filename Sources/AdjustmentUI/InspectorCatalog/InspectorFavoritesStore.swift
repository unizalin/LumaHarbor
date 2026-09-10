import Foundation

/// Persistence seam for Inspector section favorites (design spec §7.1: "收藏只存
/// 裝置本機 preferences"). A protocol so tests inject an in-memory fake instead of
/// touching real `UserDefaults`.
public protocol InspectorFavoritesPersisting: AnyObject {
    func favoriteSectionIDs() -> Set<String>
    func setFavoriteSectionIDs(_ ids: Set<String>)
}

/// Default, on-device-only implementation. Never syncs (no `NSUbiquitousKeyValueStore`),
/// matching the spec's "device-local only" requirement.
public final class UserDefaultsInspectorFavoritesStore: InspectorFavoritesPersisting {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "com.lumaharbor.inspector.favoriteSections") {
        self.defaults = defaults
        self.key = key
    }

    public func favoriteSectionIDs() -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    public func setFavoriteSectionIDs(_ ids: Set<String>) {
        defaults.set(Array(ids), forKey: key)
    }
}

/// Shared, observable favorites state both platforms attach to their
/// Inspector host. Section-level granularity (see plan §4): individual field
/// favoriting has no browsable UI surface in P2's container-only scope, and
/// this model's storage isn't tied to section identity, so extending it later
/// needs no redesign.
@MainActor
public final class InspectorFavoritesModel: ObservableObject {
    @Published public private(set) var favoriteSectionIDs: Set<InspectorSectionID>
    private let store: InspectorFavoritesPersisting

    public init(store: InspectorFavoritesPersisting = UserDefaultsInspectorFavoritesStore()) {
        self.store = store
        self.favoriteSectionIDs = Set(store.favoriteSectionIDs().compactMap(InspectorSectionID.init(rawValue:)))
    }

    public func isFavorite(_ id: InspectorSectionID) -> Bool {
        favoriteSectionIDs.contains(id)
    }

    public func toggleFavorite(_ id: InspectorSectionID) {
        if favoriteSectionIDs.contains(id) {
            favoriteSectionIDs.remove(id)
        } else {
            favoriteSectionIDs.insert(id)
        }
        store.setFavoriteSectionIDs(Set(favoriteSectionIDs.map(\.rawValue)))
    }
}
