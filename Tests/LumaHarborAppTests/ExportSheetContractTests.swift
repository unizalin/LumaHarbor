import Foundation
import XCTest

/// Same source-parsing approach as `InspectorMetadataContractTests` -- see
/// that file's own header comment for why. AwayPhotoRawEditor parity Phase 1
/// Task 4: the Mac export sheet must expose format, quality/bit-depth, size
/// caps, DPI and EXIF-retention options; keep the RAW-safety copy visible;
/// and show a distinct in-progress/succeeded state per export, all through
/// localization.
final class ExportSheetContractTests: XCTestCase {
    private static let repositoryRootURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ExportSheetContractTests.swift
            .deletingLastPathComponent() // LumaHarborAppTests
            .deletingLastPathComponent() // Tests
    }()

    private static func loadSource(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRootURL.appendingPathComponent(relativePath, isDirectory: false),
            encoding: .utf8
        )
    }

    private static func exportSheetSource() throws -> String {
        try loadSource("Sources/LumaHarborApp/Views/ExportSheet.swift")
    }

    // MARK: - Option labels

    func testExportSheetLabelsEveryFormatAwareOption() throws {
        let source = try Self.exportSheetSource()

        for key in ["Format", "Quality", "Bit Depth", "Max Width", "Max Height", "DPI", "EXIF"] {
            XCTAssertTrue(
                source.contains("L10n.t(\"\(key)\")"),
                "the export sheet must label the \(key) option through localization"
            )
        }
    }

    /// Plan: quality/bit-depth pickers must reflect what the request would
    /// actually use, not be shown unconditionally for formats that ignore
    /// them (PNG has no quality slider; only TIFF gets a bit-depth picker).
    func testQualityAndBitDepthAreGatedByTheFormatsOwnCapabilities() throws {
        let source = try Self.exportSheetSource()

        XCTAssertTrue(
            source.contains("if format.usesQuality"),
            "the quality slider must only show for formats that use quality"
        )
        XCTAssertTrue(
            source.contains("if format.supportsBitDepthChoice"),
            "the bit-depth picker must only show for formats that support a bit-depth choice"
        )
    }

    func testFormatPickerCoversEveryExportFormatCase() throws {
        let source = try Self.exportSheetSource()
        XCTAssertTrue(
            source.contains("ForEach(ExportFormat.allCases"),
            "the format picker must be driven by ExportFormat.allCases, not a hand-picked subset"
        )
    }

    func testBitDepthAndExifPickersCoverEveryCase() throws {
        let source = try Self.exportSheetSource()
        XCTAssertTrue(source.contains("ForEach(ExportBitDepth.allCases"))
        XCTAssertTrue(source.contains("ForEach(ExifRetentionPolicy.allCases"))
    }

    // MARK: - Capability guard (plan: unsupported formats must show as
    // disabled/unsupported UI, never pretend to succeed)

    func testUnsupportedFormatsAreVisiblyMarkedAndTheExportActionIsDisabled() throws {
        let source = try Self.exportSheetSource()

        XCTAssertTrue(
            source.contains("candidate.isSupported()"),
            "each format row must check its own capability, not a single global flag"
        )
        XCTAssertTrue(
            source.contains("L10n.t(\"Not Supported\")"),
            "an unsupported format's row must say so, not just quietly disable"
        )
        XCTAssertTrue(
            source.contains("!format.isSupported()"),
            "the export action must be disabled outright when the selected format has no encoder"
        )
    }

    // MARK: - RAW safety copy

    func testExportSheetShowsTheRawSafetyCopy() throws {
        let source = try Self.exportSheetSource()

        XCTAssertTrue(
            source.contains("re-decodes the original RAW at full resolution"),
            "the export sheet must tell the user the RAW is re-decoded fresh, not reused from a cache"
        )
        XCTAssertTrue(
            source.contains("L10n.t(\"Your RAW original was not changed.\")"),
            "the EXIF section must repeat the RAW-safety guarantee next to the metadata choice"
        )
    }

    // MARK: - Per-export success/failure state

    func testExportSheetShowsDistinctInProgressAndFinishedStates() throws {
        let source = try Self.exportSheetSource()

        XCTAssertTrue(source.contains("model.exportState"), "the sheet must render its state from the view model's exportState")
        XCTAssertTrue(source.contains("state.isFinished"), "the sheet must branch on whether this export has finished")
        XCTAssertTrue(source.contains("L10n.t(\"Exported\")"))
        XCTAssertTrue(source.contains("L10n.t(\"Exporting\")"))
        XCTAssertTrue(source.contains("L10n.t(\"Cancel\")"))
    }

    /// A failed export must surface as a visible failure, not silently
    /// reset to the same "nothing happening" state a cancellation shows.
    func testAFailedExportSurfacesThroughTheAlertNotAsAQuietReset() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/ViewModels/LibraryViewModel.swift")

        XCTAssertTrue(
            source.contains("UserAlert(title: L10n.t(\"Export failed\")"),
            "a thrown export error must produce a visible alert, not just clear exportState"
        )
    }

    // MARK: - Option plumbing

    /// Every option the sheet collects must actually reach `ExportRequest`
    /// through `MacExportOptions` -- not merely exist as unused `@State`.
    func testEveryCollectedOptionReachesMacExportOptions() throws {
        let source = try Self.exportSheetSource()
        let optionsBlock = try XCTUnwrap(
            source.range(of: "private var options: MacExportOptions").map { source[$0.lowerBound...] }
        )
        for field in ["format", "quality", "bitDepth", "maximumWidth", "maximumHeight", "dpi", "exifRetentionPolicy", "namingTemplate", "collisionPolicy"] {
            XCTAssertTrue(optionsBlock.contains("\(field): \(field)"), "MacExportOptions must be built from the sheet's own \(field)")
        }
        XCTAssertTrue(optionsBlock.contains("watermark: watermark"), "MacExportOptions must be built from the sheet's own computed watermark")
    }

    // MARK: - Naming template / collision policy (Phase 5 Task 5.2)

    func testExportSheetOffersANamingTemplatePickerCoveringEveryCase() throws {
        let source = try Self.exportSheetSource()
        XCTAssertTrue(source.contains("L10n.t(\"Rename\")"))
        XCTAssertTrue(source.contains("ForEach(ExportNamingTemplate.allCases"))
    }

    func testExportSheetOffersACollisionPolicyPickerCoveringEveryCase() throws {
        let source = try Self.exportSheetSource()
        XCTAssertTrue(source.contains("L10n.t(\"If a File Exists\")"))
        XCTAssertTrue(source.contains("ForEach(ExportCollisionPolicy.allCases"))
    }

    /// Mirrors `testUnsupportedFormatsAreVisiblyMarkedAndTheExportActionIsDisabled`:
    /// `.ask` has no interactive prompt implemented (see `ExportCollisionPolicy`'s
    /// own doc comment) and must be visibly marked and disable the export
    /// action, the same way an unencodable format already does -- never
    /// silently offered as if it worked.
    func testAskCollisionPolicyIsVisiblyMarkedAndDisablesTheExportAction() throws {
        let source = try Self.exportSheetSource()
        XCTAssertTrue(
            source.contains("collisionPolicy == .ask"),
            "the sheet must check specifically for .ask to mark it and disable the export action"
        )
        XCTAssertTrue(source.contains("L10n.t(\"Not Supported\")"))
    }

    // MARK: - Watermark (Phase 5 Task 5.2)

    func testExportSheetOffersAWatermarkToggleWithTextPositionOpacityAndSize() throws {
        let source = try Self.exportSheetSource()
        XCTAssertTrue(source.contains("Toggle(L10n.t(\"Add Watermark\")"))
        XCTAssertTrue(source.contains("L10n.t(\"Watermark Text\")"))
        XCTAssertTrue(source.contains("ForEach(Watermark.Position.allCases"))
        XCTAssertTrue(source.contains("L10n.t(\"Opacity\")"))
        XCTAssertTrue(source.contains("L10n.t(\"Watermark Size\")"))
    }

    /// A disabled watermark must never reach `ExportRequest` as a non-nil
    /// value with empty text -- `WatermarkRenderer` already treats that as
    /// a no-op, but the sheet shouldn't rely on that safety net alone.
    func testWatermarkIsOnlyBuiltWhenToggleIsOnAndTextIsNotBlank() throws {
        let source = try Self.exportSheetSource()
        let watermarkBlock = try XCTUnwrap(
            source.range(of: "private var watermark: Watermark?").map { source[$0.lowerBound...] }
        )
        XCTAssertTrue(watermarkBlock.contains("watermarkEnabled"))
        XCTAssertTrue(watermarkBlock.contains("isEmpty"))
    }

    // MARK: - Skip must not read as success

    func testASkippedExportShowsItsOwnCopyNotTheExportedSuccessCopy() throws {
        let source = try Self.exportSheetSource()
        XCTAssertTrue(
            source.contains("state.wasSkipped"),
            "the sheet must branch on wasSkipped, not show the same success row for a skip"
        )
        XCTAssertTrue(source.contains("L10n.t(\"Skipped\")"))
    }
}
