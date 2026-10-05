#if os(macOS)
import SwiftUI
import XCTest
@testable import AdjustmentUI

@MainActor
final class AdjustmentValueInputNativeTests: XCTestCase {
    func testControllerSubmitsChangedNativeDraftOnceAndBlurIsIdempotent() {
        var value = 6500.0
        var writes: [Double] = []
        let controller = AdjustmentInputController(
            value: Binding(get: { value }, set: { value = $0; writes.append($0) }),
            range: 2000...50000, fractionDigits: 0,
            identity: AnyHashable("photo-A-temperature"), revision: 0, unit: "K"
        )
        controller.focus()
        controller.edit("7000")
        controller.submit()
        controller.submit()
        XCTAssertEqual(value, 7000)
        XCTAssertEqual(writes, [7000])
    }

    func testControllerRejectsOutOfRangeAndRendersNativeTextAndHelp() {
        var value = 6500.0
        let controller = AdjustmentInputController(
            value: Binding(get: { value }, set: { value = $0 }),
            range: 2000...50000, fractionDigits: 0,
            identity: AnyHashable("photo-A-temperature"), revision: 0, unit: "K"
        )
        var rendered: (String, String?)?
        controller.render = { rendered = ($0, $1) }
        controller.focus()
        controller.edit("60000")
        controller.submit()
        XCTAssertEqual(value, 6500)
        XCTAssertEqual(rendered?.0, "6500")
        XCTAssertTrue(rendered?.1?.contains("2000") == true)
        XCTAssertTrue(rendered?.1?.contains("50000") == true)
    }
}
#endif
