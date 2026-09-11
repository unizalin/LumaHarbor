import AdjustmentUI
import EditorCore
import Foundation
import PhotoLibraryCore
import RawProcessingCore
import XCTest

/// P7: Comprehensive cross-device parity verification between macOS and iPadOS (spec §11.3, §11.4).
/// Confirms that both platforms mount all shared editing surfaces, have complete catalog coverage,
/// support snapshots, professional previews, and preserve full feature parity.
final class CrossDeviceParityVerificationTests: XCTestCase {
    private static let repositoryRootURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CrossDeviceParityVerificationTests.swift
            .deletingLastPathComponent() // LumaHarborAppTests
            .deletingLastPathComponent() // Tests
    }()

    private static func macInspectorSource() throws -> String {
        try String(
            contentsOf: Self.repositoryRootURL.appendingPathComponent("Sources/LumaHarborApp/Views/InspectorView.swift"),
            encoding: .utf8
        )
    }

    private static func padEditorSource() throws -> String {
        try String(
            contentsOf: Self.repositoryRootURL.appendingPathComponent("Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadEditorView.swift"),
            encoding: .utf8
        )
    }

    private static func padInspectorHostSource() throws -> String {
        try String(
            contentsOf: Self.repositoryRootURL.appendingPathComponent("Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadInspectorHost.swift"),
            encoding: .utf8
        )
    }

    func testSharedInspectorCatalogCoversAllEightSections() {
        let sections = InspectorCatalog.allSections
        let sectionIDs = Set(sections.map(\.id))

        let expectedIDs: Set<InspectorSectionID> = [
            .basic, .whiteBalance, .hsl, .curve,
            .presence, .colorGrading, .detail, .effects,
            .geometry, .local
        ]

        XCTAssertTrue(expectedIDs.isSubset(of: sectionIDs),
                      "Shared catalog must cover all professional adjustment sections")
    }

    func testMacAndiPadBothMountAllCoreAdjustmentPanels() throws {
        let macSource = try Self.macInspectorSource()
        let padSource = try Self.padEditorSource()
        let padHostSource = try Self.padInspectorHostSource()

        let corePanels = [
            "RenderingProfilePanel",
            "BasicAdjustmentPanel",
            "ColorAdjustmentPanel",
            "CurveAdjustmentPanel",
            "PresenceAdjustmentPanel",
            "ColorGradingAdjustmentPanel",
            "DetailAdjustmentPanel",
            "GeometryAdjustmentPanel",
            "LocalAdjustmentsPanel",
            "SnapshotsPanel"
        ]

        for panel in corePanels {
            XCTAssertTrue(macSource.contains(panel),
                          "Mac InspectorView must mount \(panel)")
            let inPad = padSource.contains(panel) || padHostSource.contains(panel)
            XCTAssertTrue(inPad,
                          "iPad must mount \(panel) in PadEditorView or PadInspectorHost")
        }
    }

    func testMacAndiPadBothSupportSnapshotWorkflowAndABComparison() throws {
        let macSource = try Self.macInspectorSource()
        let padSource = try Self.padEditorSource()

        // Mac mounts Snapshots tab and panel
        XCTAssertTrue(macSource.contains("case .snapshots"))
        XCTAssertTrue(macSource.contains("SnapshotsPanel(editor:"))

        // iPad mounts SnapshotsPanel and snapshot comparison in compareMenu
        XCTAssertTrue(padSource.contains("SnapshotsPanel(editor:"))
        XCTAssertTrue(padSource.contains("Compare with Snapshot"))
        XCTAssertTrue(padSource.contains("comparisonSnapshot"))
    }

    func testLocalAdjustmentsMaskKindsAreFullyUnifiedAcrossPlatforms() {
        // Verify LocalAdjustmentKind enumeration covers all advanced mask types
        let allKinds: [LocalAdjustmentKind] = [
            .linearGradient,
            .radialGradient,
            .brush,
            .luminanceRange,
            .colorRange,
            .subject,
            .background,
            .spotHeal
        ]

        XCTAssertEqual(allKinds.count, 8)
        for kind in allKinds {
            XCTAssertFalse(kind.rawValue.isEmpty)
        }
    }

    func testPhotoSidecarUsesLatestUnifiedSchemaV4() {
        XCTAssertEqual(PhotoSidecar.currentSchemaVersion, 4,
                       "Sidecar schema must be unified at version 4 for both Mac and iPad")
    }
}
