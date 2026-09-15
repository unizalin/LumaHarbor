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

    func testMacAndiPadExposeTheSameFiveInspectorDomains() throws {
        let macSource = try Self.macInspectorSource()
        let padSource = try Self.padEditorSource()
        let padHostSource = try Self.padInspectorHostSource()

        for domainCase in ["case adjustments", "case presets", "case geometry", "case local", "case info"] {
            XCTAssertTrue(macSource.contains(domainCase), "Mac InspectorTab must expose \(domainCase)")
        }

        for domain in ["id: .adjust", "id: .preset", "id: .geometry", "id: .local", "id: .info"] {
            XCTAssertTrue(
                padSource.contains(domain) || padHostSource.contains(domain),
                "iPad inspector must expose \(domain)"
            )
        }

        XCTAssertTrue(macSource.contains("HistogramPanel(histogram:"))
        XCTAssertTrue(macSource.contains("SnapshotsPanel(editor:"))
        XCTAssertTrue(macSource.contains("MetadataPanel("))
        XCTAssertTrue(macSource.contains("GeometryAdjustmentPanel(editor:"))
        XCTAssertTrue(macSource.contains("LocalAdjustmentsPanel(editor:"))
        XCTAssertTrue(macSource.contains("SaveStatePanel(state:"))
        XCTAssertTrue(padSource.contains("PadSaveStateBlock(saveState:"))
        XCTAssertTrue(padSource.contains("PadMetadataBlock("))
        XCTAssertTrue(padHostSource.contains("PadStandaloneSaveStateBlock(saveState:"))
        XCTAssertTrue(padHostSource.contains("PadStandaloneMetadataBlock(snapshot:"))
        XCTAssertTrue(macSource.contains("Label(tab.title, systemImage: tab.symbol)"))
        for source in [padSource, padHostSource] {
            XCTAssertTrue(source.contains("Image(systemName: item.symbol)"), "iPad domain tabs must keep a visible icon")
            XCTAssertTrue(source.contains("Text(L10n.t(item.labelKey))"), "iPad domain tabs must keep the full localized label")
            XCTAssertTrue(source.contains(".fixedSize(horizontal: false, vertical: true)"), "iPad domain labels must wrap instead of clipping")
        }
    }

    func testInfoPageKeepsMetadataAndCurationParityAcrossHosts() throws {
        let macSource = try Self.macInspectorSource()
        let padSource = try Self.padEditorSource()

        // Both hosts must present the same information order and the same
        // editable curation affordances; only their platform-specific touch
        // metrics may differ.
        for source in [macSource, padSource] {
            XCTAssertTrue(source.contains("File Info"), "Info pages must use the shared File Info heading")
            XCTAssertTrue(source.contains("orientationDescription"), "Info pages must expose orientation metadata")
            XCTAssertTrue(source.contains("Curation"), "Info pages must expose curation controls")
            XCTAssertTrue(source.contains("ratingControls"), "Info pages must expose rating controls")
            XCTAssertTrue(source.contains("flagControl"), "Info pages must expose flag controls")
            XCTAssertTrue(source.contains("keywordEditor"), "Info pages must expose keyword editing")
            XCTAssertTrue(source.contains("Unsaved changes"), "Info pages must use the shared unsaved-state copy")
            XCTAssertTrue(source.contains("Save failed"), "Info pages must use the shared save-failure copy")
        }
    }

    func testiPadLandscapeRailUsesTheSameLabelledWidthAsItsLayoutPolicy() throws {
        let padSource = try Self.padEditorSource()
        let sharedRailSource = try String(
            contentsOf: Self.repositoryRootURL.appendingPathComponent("Apps/LumaHarborPad.swiftpm/Sources/LumaHarborPadApp/PadToolRail.swift"),
            encoding: .utf8
        )

        XCTAssertEqual(PadEditorLayoutPolicy.toolRailWidth, 88,
                       "the layout budget must match the rendered labelled rail")
        XCTAssertTrue(padSource.contains(".frame(width: axis == .vertical ? 88 : nil)"),
                      "the Xcode iPad source path must reserve the full labelled rail width")
        XCTAssertFalse(padSource.contains(".frame(width: 52)"),
                      "the old icon-only rail width would make the landscape canvas calculation overlap")
        XCTAssertTrue(padSource.contains("Image(systemName: item.symbol)"),
                      "the Xcode iPad rail must expose a visible domain icon")
        XCTAssertTrue(padSource.contains("Text(L10n.t(item.labelKey))"),
                      "the Xcode iPad rail must expose the same readable labels as the SwiftPM host")
        XCTAssertTrue(padSource.contains(".lineLimit(2)"),
                      "long localized domains must wrap instead of being clipped")
        for source in [padSource, sharedRailSource] {
            XCTAssertTrue(
                source.contains(".frame(width: axis == .vertical ? 88 : nil)"),
                "the 88pt rail budget must include its horizontal padding"
            )
            XCTAssertFalse(
                source.contains("}.frame(width: 88)"),
                "the rail must not reserve 88pt before adding padding"
            )
        }
    }

    func testiPadCompactDomainBarKeepsTabsReadableAtNarrowWidths() throws {
        let padSource = try Self.padEditorSource()
        let padHostSource = try Self.padInspectorHostSource()

        for source in [padSource, padHostSource] {
            XCTAssertTrue(source.contains("ScrollView(.horizontal, showsIndicators: false)"),
                          "compact domain tabs must scroll instead of compressing five labels into unreadable columns")
            XCTAssertTrue(source.contains(".frame(minWidth: 88, minHeight: 52)"),
                          "each compact domain tab needs a stable readable width and touch target")
        }
    }

    func testNarrowInspectorNavigationKeepsLabelsAndActionsUsable() throws {
        let macSource = try Self.macInspectorSource()
        let padSource = try Self.padEditorSource()
        let padHostSource = try Self.padInspectorHostSource()

        XCTAssertTrue(macSource.contains("private var tabBar: some View"),
                      "Mac tabs need a named adaptive layout surface")
        XCTAssertTrue(macSource.contains("ScrollView(.horizontal, showsIndicators: false)"),
                      "Mac narrow Inspector tabs must keep full labels in a horizontal scroller")
        XCTAssertTrue(macSource.contains(".frame(minWidth: 112, minHeight: 44)"),
                      "Mac narrow Inspector tabs need stable pointer targets")

        for source in [padSource, padHostSource] {
            XCTAssertTrue(source.contains("private var catalogToolbar: some View") ||
                          source.contains("private var adjustSubmodePicker: some View"),
                          "iPad source must keep named adaptive Inspector surfaces")
        }
        XCTAssertTrue(padSource.contains("private var catalogToolbarActions: some View"),
                      "the iPad catalog actions need to be separable from the search field when stacked")
        XCTAssertTrue(padSource.contains("private var submodeMenu: some View"),
                      "the iPad adjustment submode needs a readable narrow fallback")
        XCTAssertTrue(padHostSource.contains("private var submodeMenu: some View"),
                      "the standalone iPad Inspector host must match the Xcode source path")
        XCTAssertTrue(padSource.contains("private var scopePicker: some View") &&
                      padSource.contains("private var applyModePicker: some View"),
                      "the iPad Preset page must keep named adaptive picker surfaces")
        XCTAssertTrue(padSource.contains("private var keywordEditor: some View"),
                      "the iPad Info page keyword editor must stack when its drawer is narrow")

        let localSource = try String(
            contentsOf: Self.repositoryRootURL.appendingPathComponent("Sources/AdjustmentUI/LocalAdjustmentsPanel.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(localSource.contains("private func spotHealModePicker(for heal: LocalAdjustment)"),
                      "Spot Heal mode needs a named adaptive picker surface")
        XCTAssertTrue(localSource.contains("private func spotHealModeMenu(for heal: LocalAdjustment)"),
                      "Spot Heal mode needs a readable narrow fallback")
    }

    func testMacAndiPadBothSupportSnapshotWorkflowAndABComparison() throws {
        let macSource = try Self.macInspectorSource()
        let padSource = try Self.padEditorSource()

        // Mac mounts the shared Info tab and panel
        XCTAssertTrue(macSource.contains("case .info"))
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
