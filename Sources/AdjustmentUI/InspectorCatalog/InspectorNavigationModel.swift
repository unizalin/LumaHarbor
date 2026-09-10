import Combine
import EditorCore
import Foundation

/// Shared navigation state for the Inspector, owned once per open editor and
/// attached by both Mac's `InspectorView` and iPad's `PadInspectorHost`
/// (design spec §7.1: search, favorites, smart follow, pin). Neither platform
/// keeps its own copy of this state machine.
@MainActor
public final class InspectorNavigationModel: ObservableObject {
    @Published public var searchQuery: String = ""
    @Published public private(set) var isPinned: Bool = false
    @Published public private(set) var activeSectionID: InspectorSectionID

    private let favorites: InspectorFavoritesModel
    private var favoritesSubscription: AnyCancellable?

    public init(
        initialSection: InspectorSectionID = .basic,
        favorites: InspectorFavoritesModel? = nil
    ) {
        self.activeSectionID = initialSection
        let favorites = favorites ?? InspectorFavoritesModel()
        self.favorites = favorites
        // `favorites` is a nested ObservableObject -- its own `@Published`
        // changes don't automatically republish through this object's
        // `objectWillChange`, so a view observing only `InspectorNavigationModel`
        // would silently miss favorite toggles without this forwarding.
        self.favoritesSubscription = favorites.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// Sections matching `searchQuery`. Empty query -> empty results (the
    /// caller shows favorites/browse UI instead of a "type to search" list),
    /// matching `InspectorCatalog.search`'s own contract.
    public var searchResults: [InspectorSectionDescriptor] {
        InspectorCatalog.search(searchQuery)
    }

    public func clearSearch() {
        searchQuery = ""
    }

    public func togglePin() {
        isPinned.toggle()
    }

    /// Explicit navigation -- a search-result tap or a favorite tap. Always
    /// takes effect, even while pinned: pin only suppresses *automatic*
    /// smart-follow moves, never something the user just tapped.
    public func select(_ section: InspectorSectionID) {
        activeSectionID = section
    }

    /// Called on every `EditorSession.toolMode` change. No-op while pinned or
    /// when `toolMode` has no section mapping.
    public func follow(toolMode: EditorToolMode) {
        guard !isPinned, let section = InspectorSmartFollow.section(for: toolMode) else { return }
        activeSectionID = section
    }

    public func isFavorite(_ section: InspectorSectionID) -> Bool {
        favorites.isFavorite(section)
    }

    public func toggleFavorite(_ section: InspectorSectionID) {
        favorites.toggleFavorite(section)
    }
}
