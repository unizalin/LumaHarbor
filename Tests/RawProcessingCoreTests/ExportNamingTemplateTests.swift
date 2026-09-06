import Foundation
import XCTest
@testable import RawProcessingCore

/// Roadmap Phase 5 Task 5.2: "Add naming template tests: original filename,
/// sequence, date, preset name, virtual copy name" -- design spec §6.11's
/// "重新命名規則:原檔名、序號、日期、preset name、virtual copy name". Each
/// template is a pure `Context -> String` function so it's testable with no
/// decoder, file system, or UI.
final class ExportNamingTemplateTests: XCTestCase {
    private func context(
        originalFilename: String = "DSC0001",
        sequence: Int = 1,
        date: Date? = nil,
        presetName: String? = nil,
        virtualCopyName: String? = nil
    ) -> ExportNamingTemplate.Context {
        ExportNamingTemplate.Context(
            originalFilename: originalFilename,
            sequence: sequence,
            date: date,
            presetName: presetName,
            virtualCopyName: virtualCopyName
        )
    }

    // MARK: - Original filename

    func testOriginalFilenameTemplateReturnsTheFilenameUnchanged() {
        let result = ExportNamingTemplate.originalFilename.render(context(originalFilename: "IMG_1234"))
        XCTAssertEqual(result, "IMG_1234")
    }

    // MARK: - Sequence

    func testSequenceTemplateAppendsAZeroPaddedThreeDigitNumber() {
        let result = ExportNamingTemplate.originalFilenameWithSequence.render(context(originalFilename: "IMG_1234", sequence: 7))
        XCTAssertEqual(result, "IMG_1234_007")
    }

    func testSequenceTemplateDoesNotTruncateNumbersLargerThanThreeDigits() {
        let result = ExportNamingTemplate.originalFilenameWithSequence.render(context(originalFilename: "A", sequence: 1234))
        XCTAssertEqual(result, "A_1234")
    }

    // MARK: - Date

    func testDateTemplatePrefixesAnISOStyleDate() {
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 5
        let date = Calendar(identifier: .gregorian).date(from: components)
        let result = ExportNamingTemplate.dateAndOriginalFilename.render(context(originalFilename: "IMG_1234", date: date))
        XCTAssertEqual(result, "2026-03-05_IMG_1234")
    }

    func testDateTemplateWithNoCaptureDateFallsBackHonestlyRatherThanGuessing() {
        let result = ExportNamingTemplate.dateAndOriginalFilename.render(context(originalFilename: "IMG_1234", date: nil))
        XCTAssertEqual(result, "NoDate_IMG_1234", "no capture date means no date, never today's date standing in for it")
    }

    // MARK: - Preset name

    func testPresetNameTemplatePrefixesThePresetsName() {
        let result = ExportNamingTemplate.presetNameAndOriginalFilename.render(
            context(originalFilename: "IMG_1234", presetName: "Warm Film")
        )
        XCTAssertEqual(result, "Warm Film_IMG_1234")
    }

    func testPresetNameTemplateWithNoPresetFallsBackToTheOriginalFilename() {
        let result = ExportNamingTemplate.presetNameAndOriginalFilename.render(
            context(originalFilename: "IMG_1234", presetName: nil)
        )
        XCTAssertEqual(result, "IMG_1234")
    }

    func testPresetNameTemplateWithAnEmptyPresetNameFallsBackToTheOriginalFilename() {
        let result = ExportNamingTemplate.presetNameAndOriginalFilename.render(
            context(originalFilename: "IMG_1234", presetName: "")
        )
        XCTAssertEqual(result, "IMG_1234")
    }

    // MARK: - Virtual copy name

    func testVirtualCopyNameTemplateAppendsTheCopysName() {
        let result = ExportNamingTemplate.originalFilenameWithVirtualCopyName.render(
            context(originalFilename: "IMG_1234", virtualCopyName: "B&W")
        )
        XCTAssertEqual(result, "IMG_1234_B&W")
    }

    func testVirtualCopyNameTemplateWithNoCopyNameFallsBackToTheOriginalFilename() {
        let result = ExportNamingTemplate.originalFilenameWithVirtualCopyName.render(
            context(originalFilename: "IMG_1234", virtualCopyName: nil)
        )
        XCTAssertEqual(result, "IMG_1234")
    }

    // MARK: - Display names / coverage

    func testEveryTemplateHasAVisibleDisplayName() {
        for template in ExportNamingTemplate.allCases {
            XCTAssertFalse(template.displayName.isEmpty, "\(template) has no display name")
        }
    }

    func testDefaultTemplateIsOriginalFilenamePreservingExistingBehaviour() {
        XCTAssertEqual(ExportNamingTemplate.originalFilename, ExportNamingTemplate.default)
    }
}
