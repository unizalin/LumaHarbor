import Foundation

/// Pure Inspector workspace policy. Expansion and pinning are presentation
/// state only; they never participate in photo adjustments, sidecars, or
/// photo undo history.
enum InspectorGroup: String, CaseIterable, Hashable {
    case basic
    case color
    case curve
    case detail
    case effects
    case geometry
    case local
}

struct InspectorLayoutState: Equatable {
    var expandedGroups: Set<InspectorGroup>
    var pinnedGroups: Set<InspectorGroup>
    var soloMode: Bool

    init(
        expandedGroups: Set<InspectorGroup> = [.basic, .color],
        pinnedGroups: Set<InspectorGroup> = [],
        soloMode: Bool = false
    ) {
        self.expandedGroups = expandedGroups
        self.pinnedGroups = pinnedGroups
        self.soloMode = soloMode
    }

    mutating func setExpanded(_ group: InspectorGroup, isExpanded: Bool) {
        guard isExpanded else {
            expandedGroups.remove(group)
            return
        }

        if soloMode {
            expandedGroups = expandedGroups.intersection(pinnedGroups)
        }
        expandedGroups.insert(group)
    }

    mutating func togglePinned(_ group: InspectorGroup) {
        if pinnedGroups.contains(group) {
            pinnedGroups.remove(group)
        } else {
            pinnedGroups.insert(group)
        }
    }
}
