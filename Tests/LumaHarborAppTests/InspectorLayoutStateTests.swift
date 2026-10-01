import XCTest
@testable import LumaHarborApp

final class InspectorLayoutStateTests: XCTestCase {
    func testSoloModeCollapsesOtherUnpinnedGroupsWhenOpeningAGroup() {
        var state = InspectorLayoutState(
            expandedGroups: [.basic, .color, .detail],
            pinnedGroups: [.basic],
            soloMode: true
        )

        state.setExpanded(.geometry, isExpanded: true)

        XCTAssertEqual(state.expandedGroups, [.basic, .geometry])
    }

    func testSoloModeLeavesPinnedGroupsExpandedWhenOpeningAnotherGroup() {
        var state = InspectorLayoutState(
            expandedGroups: [.basic, .color],
            pinnedGroups: [.basic, .color],
            soloMode: true
        )

        state.setExpanded(.detail, isExpanded: true)

        XCTAssertEqual(state.expandedGroups, [.basic, .color, .detail])
    }

    func testTurningAGroupOffNeverChangesPinnedMembership() {
        var state = InspectorLayoutState(
            expandedGroups: [.basic, .detail],
            pinnedGroups: [.detail],
            soloMode: true
        )

        state.setExpanded(.detail, isExpanded: false)

        XCTAssertEqual(state.expandedGroups, [.basic])
        XCTAssertEqual(state.pinnedGroups, [.detail])
    }
}
