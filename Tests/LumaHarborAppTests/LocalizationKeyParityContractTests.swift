import Foundation
import XCTest

/// P2 (`2026-09-10-shared-professional-inspector-catalog.md` §6): all 8
/// shipped languages must declare exactly the same `Localizable.strings` key
/// set (AGENTS.md: "所有使用者文字接入現有八語 localization，至少驗證中英文內容與
/// 全語系 key parity"). This is the first automated key-parity check in this
/// repository -- prior to this task the 8 files happened to agree by
/// convention, with nothing enforcing it. `en`/`zh-Hant` values are also
/// checked for the P2-added keys specifically, so a lazy passthrough
/// (English text copied into a non-English file) is caught, not just a
/// missing key.
final class LocalizationKeyParityContractTests: XCTestCase {
    private static let languages = ["en", "zh-Hant", "zh-Hans", "ja", "ko", "es", "fr", "de"]

    private static let repositoryRootURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // LocalizationKeyParityContractTests.swift
            .deletingLastPathComponent() // LumaHarborAppTests
            .deletingLastPathComponent() // Tests
    }()

    private static func keys(for language: String) throws -> [String: String] {
        let url = Self.repositoryRootURL
            .appendingPathComponent("Sources/Localization/Resources/\(language).lproj/Localizable.strings")
        let data = try Data(contentsOf: url)
        var format = PropertyListSerialization.PropertyListFormat.openStep
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        guard let table = plist as? [String: String] else {
            throw NSError(domain: "LocalizationKeyParityContractTests", code: 1)
        }
        return table
    }

    func testEveryLanguageFileParsesAsAValidStringsTable() throws {
        for language in Self.languages {
            let table = try Self.keys(for: language)
            XCTAssertFalse(table.isEmpty, "\(language).lproj/Localizable.strings must not be empty")
        }
    }

    func testAllEightLanguagesDeclareTheExactSameKeySet() throws {
        let englishKeys = Set(try Self.keys(for: "en").keys)
        for language in Self.languages where language != "en" {
            let keys = Set(try Self.keys(for: language).keys)
            let missing = englishKeys.subtracting(keys)
            let extra = keys.subtracting(englishKeys)
            XCTAssertTrue(missing.isEmpty, "\(language).lproj is missing keys: \(missing.sorted())")
            XCTAssertTrue(extra.isEmpty, "\(language).lproj has extra keys not in en.lproj: \(extra.sorted())")
        }
    }

    func testNoLanguageHasAnEmptyValueForAnyKey() throws {
        for language in Self.languages {
            let table = try Self.keys(for: language)
            for (key, value) in table {
                XCTAssertFalse(value.isEmpty, "\(language).lproj key \"\(key)\" has an empty value")
            }
        }
    }

    // MARK: - P2-added keys: present, non-empty, and (en/zh-Hant) not a lazy passthrough

    private static let p2Keys = [
        "Search Adjustments", "Clear Search", "No matching tools",
        "Add to Favorites", "Remove from Favorites",
        "Pin Section", "Unpin Section",
        "Reset Adjust", "Reset Geometry", "Reset Local Adjustments",
    ]

    func testP2KeysExistInEveryLanguage() throws {
        for language in Self.languages {
            let table = try Self.keys(for: language)
            for key in Self.p2Keys {
                XCTAssertNotNil(table[key], "\(language).lproj is missing P2 key \"\(key)\"")
            }
        }
    }

    func testP2KeysHaveManuallyTranslatedTraditionalChineseValues() throws {
        let english = try Self.keys(for: "en")
        let traditionalChinese = try Self.keys(for: "zh-Hant")
        for key in Self.p2Keys {
            let englishValue = english[key]
            let chineseValue = traditionalChinese[key]
            XCTAssertNotEqual(
                chineseValue, englishValue,
                "zh-Hant value for \"\(key)\" must be a real translation, not the English text copied through"
            )
        }
    }
}
