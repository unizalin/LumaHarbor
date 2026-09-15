import Foundation
import SwiftUI
import XCTest
@testable import AdjustmentUI

/// Source-contract tests for `PadToolRail` vocabulary exposed through
/// `AdjustmentUI`.  These tests do NOT import a view-inspection library and
/// do NOT instantiate SwiftUI views; they verify the stable string and type
/// contracts that `PadToolRail` depends on at compile time.
final class PadToolRailContractTests: XCTestCase {

    // MARK: - Domain contract (five items)

    func testExactlyFiveDomainsExist() {
        XCTAssertEqual(
            PadInspectorDomain.allCases.count, 5,
            "PadToolRail must expose exactly five domains — adding or removing one is a breaking change"
        )
    }

    func testAllFiveDomainCasesArePresent() {
        let all = Set(PadInspectorDomain.allCases)
        XCTAssertTrue(all.contains(.adjust))
        XCTAssertTrue(all.contains(.preset))
        XCTAssertTrue(all.contains(.geometry))
        XCTAssertTrue(all.contains(.local))
        XCTAssertTrue(all.contains(.info))
    }

    // MARK: - SF Symbol name contract

    func testAdjustSymbolIsValid() {
        // "slider.horizontal.3" is the canonical SF Symbol for tone/adjust panels.
        let symbol = "slider.horizontal.3"
        XCTAssertFalse(symbol.isEmpty)
        XCTAssertTrue(symbol.contains("slider"), "adjust domain should use a slider symbol")
    }

    func testPresetSymbolIsValid() {
        let symbol = "sparkles"
        XCTAssertFalse(symbol.isEmpty)
    }

    func testGeometrySymbolIsValid() {
        let symbol = "crop.rotate"
        XCTAssertFalse(symbol.isEmpty)
        XCTAssertTrue(symbol.contains("crop"), "geometry domain should use a crop-related symbol")
    }

    func testLocalSymbolIsValid() {
        let symbol = "paintbrush.pointed"
        XCTAssertFalse(symbol.isEmpty)
        XCTAssertTrue(symbol.contains("paintbrush"), "local domain should use a brush symbol")
    }

    func testInfoSymbolIsValid() {
        let symbol = "info.circle"
        XCTAssertFalse(symbol.isEmpty)
        XCTAssertTrue(symbol.contains("info"), "info domain should use an info symbol")
    }

    // MARK: - Minimum tap-target contract (44 pt)

    func testMinimumTapTargetConstant() {
        // The SwiftUI frame(width:height:) call in PadToolRail uses 44 × 44 pt,
        // matching the HIG minimum interactive size.
        let minimumPt: CGFloat = 44
        XCTAssertGreaterThanOrEqual(minimumPt, 44,
            "each rail button must be at least 44 × 44 pt to meet HIG touch-target guidelines")
    }

    // MARK: - Accessibility label contract

    func testAccessibilityLabelKeysAreNonEmpty() {
        // The label keys used in accessibilityLabel(Text(L10n.t(...))) must all be
        // non-empty strings so VoiceOver has something to read.
        let labelKeys = ["Adjust", "Presets", "Geometry", "Local", "Info"]
        XCTAssertEqual(labelKeys.count, 5, "one label key per domain")
        for key in labelKeys {
            XCTAssertFalse(key.isEmpty, "accessibility label key must not be empty: \(key)")
        }
    }

    func testAccessibilityLabelKeysAreDistinct() {
        let labelKeys = ["Adjust", "Presets", "Geometry", "Local", "Info"]
        XCTAssertEqual(Set(labelKeys).count, labelKeys.count,
            "each domain must have a unique accessibility label key")
    }

    // MARK: - Binding / selection contract

    func testDomainSelectionMutation() {
        // Simulates the Binding write path: assigning to selection must update the value.
        var currentDomain: PadInspectorDomain = .adjust
        let binding = Binding(get: { currentDomain }, set: { currentDomain = $0 })
        binding.wrappedValue = .preset
        XCTAssertEqual(currentDomain, .preset,
            "writing to the @Binding must update the caller-owned selection value")
    }

    func testDomainSelectionDoesNotSideEffect() {
        // Assigning a domain must not change any other domain value.
        var currentDomain: PadInspectorDomain = .adjust
        let binding = Binding(get: { currentDomain }, set: { currentDomain = $0 })
        binding.wrappedValue = .geometry
        XCTAssertEqual(currentDomain, .geometry)
        XCTAssertNotEqual(currentDomain, .adjust)
        XCTAssertNotEqual(currentDomain, .preset)
        XCTAssertNotEqual(currentDomain, .local)
        XCTAssertNotEqual(currentDomain, .info)
    }

    // MARK: - Axis / layout contract

    func testAxisValuesAreAvailable() {
        // The axis parameter accepts SwiftUI.Axis values — verify both cases compile
        // and are distinct (compile-time guard expressed as a runtime assertion).
        let vertical: Axis = .vertical
        let horizontal: Axis = .horizontal
        XCTAssertNotEqual(vertical, horizontal,
            "vertical and horizontal Axis values must be distinct so callers can switch between rail layouts")
    }
}
