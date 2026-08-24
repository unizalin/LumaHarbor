import XCTest
@testable import EditorCore

final class EditorDependenciesTests: XCTestCase {
    func testEditorAlertKeepsActionableCopySeparate() {
        let alert = EditorAlert(title: "Open failed", message: "Unreadable", nextStep: "Choose another file")
        XCTAssertEqual(alert.title, "Open failed")
        XCTAssertEqual(alert.message, "Unreadable")
        XCTAssertEqual(alert.nextStep, "Choose another file")
    }
}
