import Foundation
import XCTest
@testable import LumaHarborApp

final class LocalizationSmokeTest: XCTestCase {
    /// Loads the sub-bundle for one specific `.lproj` directly, bypassing
    /// system-language resolution entirely, so this test proves what each
    /// translation file actually contains rather than what this machine's
    /// current language happens to pick.
    private func string(_ key: String, lproj: String) throws -> String {
        let path = try XCTUnwrap(Bundle.module.path(forResource: lproj, ofType: "lproj"))
        let langBundle = try XCTUnwrap(Bundle(path: path))
        return langBundle.localizedString(forKey: key, value: nil, table: "Localizable")
    }

    func testEnglishTranslationResolves() throws {
        XCTAssertEqual(try string("Cancel", lproj: "en"), "Cancel")
        XCTAssertEqual(try string("Add a photo folder", lproj: "en"), "Add a photo folder")
    }

    func testChineseTranslationResolves() throws {
        // SwiftPM's resource copier lowercases the `.lproj` directory name
        // (`zh-Hant.lproj` on disk becomes `zh-hant.lproj` in the built
        // bundle); macOS's own system-language resolution matches this
        // case-insensitively, but a direct path lookup here has to use the
        // name SwiftPM actually produced.
        XCTAssertEqual(try string("Cancel", lproj: "zh-hant"), "取消")
        XCTAssertEqual(try string("Add a photo folder", lproj: "zh-hant"), "加入照片資料夾")
    }
}
