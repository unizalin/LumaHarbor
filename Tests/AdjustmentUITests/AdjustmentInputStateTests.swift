import XCTest
@testable import AdjustmentUI

final class AdjustmentInputStateTests: XCTestCase {
    private func make(_ value: Double = 6500) -> AdjustmentInputState {
        AdjustmentInputState(value: value, range: 2000...50000, fractionDigits: 0,
            identity: AnyHashable("A-temperature"), revision: 0)
    }

    func testUntouchedFocusAndRepeatedFinishNeverWriteOrRound() {
        var state = make(4536.72802734375)
        state.focus()
        XCTAssertEqual(state.draft, "4536.72802734375")
        XCTAssertNil(state.submit())
        XCTAssertNil(state.submit())
        XCTAssertEqual(state.value, 4536.72802734375)
    }

    func testExplicitDisplayRoundedValueCommitsOnce() {
        var state = make(4536.72802734375)
        state.focus(); state.edit("4537")
        XCTAssertEqual(state.submit(), 4537)
        XCTAssertNil(state.submit())
    }

    func testInvalidDraftRestoresAndRetainsErrorAfterBlur() {
        for text in ["", "-", "+", ".", "text", "NaN", "Infinity", "1999", "50001"] {
            var state = make()
            state.focus(); state.edit(text)
            XCTAssertNil(state.submit(), text)
            XCTAssertEqual(state.draft, "6500")
            XCTAssertNotNil(state.error)
            XCTAssertNil(state.submit())
            XCTAssertNotNil(state.error)
            XCTAssertEqual(state.value, 6500)
        }
    }

    func testEscapeAndContextChangeInvalidateOldDraft() {
        var state = make()
        state.focus(); state.edit("7000"); state.cancel()
        XCTAssertNil(state.submit())
        state.focus(); state.edit("7000")
        state.synchronize(value: 6500, identity: AnyHashable("A-temperature"), revision: 1)
        XCTAssertNil(state.submit())
        state.focus(); state.edit("7000")
        state.synchronize(value: 6500, identity: AnyHashable("B-temperature"), revision: 1)
        XCTAssertNil(state.submit())
        XCTAssertEqual(state.draft, "6500")
    }

    func testNudgeUsesExactDraftAndWritesOnlyFinalResult() {
        var state = make(4536.72802734375)
        state.focus(); state.edit("6000.125")
        XCTAssertEqual(state.nudge(by: 50), 6050.125)
        XCTAssertNil(state.submit())
        state.focus(); state.edit("bad")
        XCTAssertEqual(state.nudge(by: 50), 6100.125)
        XCTAssertNil(state.submit())
    }
}
