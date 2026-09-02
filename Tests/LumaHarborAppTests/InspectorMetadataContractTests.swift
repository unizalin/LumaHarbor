import Foundation
import XCTest

/// `InspectorView.swift`'s SwiftUI body can't be instantiated and inspected
/// from `swift test` without a third-party view-inspection library, and this
/// package is deliberately dependency-free -- so, matching the same
/// established pattern the iPad app's own contract tests already use for the
/// same reason, this source-parses the raw file text instead of exercising
/// the view tree.
///
/// AwayPhotoRawEditor parity Phase 1 Task 1: the Mac editor's right-side
/// panel must show a dedicated metadata/EXIF section built from
/// `EditorMetadataSnapshot`, with every visible label routed through
/// `L10n.t` rather than a hard-coded English string.
final class InspectorMetadataContractTests: XCTestCase {
    private static let repositoryRootURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // InspectorMetadataContractTests.swift
            .deletingLastPathComponent() // LumaHarborAppTests
            .deletingLastPathComponent() // Tests
    }()

    private static func appSourceURL(_ filename: String) -> URL {
        repositoryRootURL
            .appendingPathComponent("Sources/LumaHarborApp/Views", isDirectory: true)
            .appendingPathComponent(filename)
    }

    private static func loadSource(_ filename: String) throws -> String {
        try String(contentsOf: appSourceURL(filename), encoding: .utf8)
    }

    func testInspectorViewRendersAMetadataSectionFromTheSnapshotModel() throws {
        let source = try Self.loadSource("InspectorView.swift")

        XCTAssertTrue(
            source.contains("EditorMetadataSnapshot(photo:"),
            "InspectorView must build its metadata panel from EditorMetadataSnapshot, not re-derive metadata text itself"
        )
        XCTAssertTrue(
            source.contains("L10n.t(\"Metadata\")"),
            "the metadata section must have a visible, localized header"
        )
    }

    /// Every field the Phase 1 plan's Task 1 user-outcome line calls out by
    /// name: filename, format, pixel dimensions, file size, camera, lens,
    /// focal length, aperture, shutter speed, ISO, capture date, orientation.
    func testInspectorViewLabelsEveryPhase1MetadataFieldThroughLocalization() throws {
        let source = try Self.loadSource("InspectorView.swift")

        for key in [
            "Filename", "Format", "Dimensions", "File Size", "Camera", "Lens",
            "Focal Length", "Aperture", "Shutter Speed", "ISO", "Capture Date", "Orientation"
        ] {
            XCTAssertTrue(
                source.contains("L10n.t(\"\(key)\")"),
                "the metadata panel must label the \(key) field through localization, not a hard-coded string"
            )
        }
    }

    /// Acceptance: "File path shown to users is basename or source-safe
    /// display name, not private absolute path." Nothing in this file may
    /// read `sourceURL`'s own path directly for display -- every value must
    /// come from the pre-formatted, path-safe snapshot.
    func testInspectorViewNeverRendersARawSourceURLPath() throws {
        let source = try Self.loadSource("InspectorView.swift")

        XCTAssertFalse(
            source.contains("sourceURL.path") || source.contains("sourceURL!.path"),
            "the metadata panel must never render a source URL's raw filesystem path"
        )
    }
}
