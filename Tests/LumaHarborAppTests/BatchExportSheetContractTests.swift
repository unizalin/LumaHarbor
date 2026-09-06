import Foundation
import XCTest

/// Same source-parsing approach as `ExportSheetContractTests` -- see that
/// file's own header comment for why. Phase 5 Task 5.1 UI/action wiring
/// follow-up: the Mac batch export queue must expose the same format/size/
/// DPI/EXIF options a single export does, show live per-file pending/
/// running/succeeded/failed/cancelled status, a running total, and a cancel
/// action -- and must never render a finished-with-failures batch as if it
/// were all-succeeded (design spec §8.3: "failed / skipped / not run 不得
/// 偽裝成成功").
final class BatchExportSheetContractTests: XCTestCase {
    private static let repositoryRootURL: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // BatchExportSheetContractTests.swift
            .deletingLastPathComponent() // LumaHarborAppTests
            .deletingLastPathComponent() // Tests
    }()

    private static func loadSource(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRootURL.appendingPathComponent(relativePath, isDirectory: false),
            encoding: .utf8
        )
    }

    private static func batchExportSheetSource() throws -> String {
        try loadSource("Sources/LumaHarborApp/Views/BatchExportSheet.swift")
    }

    // MARK: - Option plumbing, reused from the single-photo sheet

    func testBatchExportSheetLabelsEveryFormatAwareOption() throws {
        let source = try Self.batchExportSheetSource()
        for key in ["Format", "Quality", "Bit Depth", "Max Width", "Max Height", "DPI", "EXIF"] {
            XCTAssertTrue(
                source.contains("L10n.t(\"\(key)\")"),
                "the batch export sheet must label the \(key) option through localization"
            )
        }
    }

    func testBatchExportSheetOptionsReachMacExportOptions() throws {
        let source = try Self.batchExportSheetSource()
        let optionsBlock = try XCTUnwrap(
            source.range(of: "private var options: MacExportOptions").map { source[$0.lowerBound...] }
        )
        for field in ["format", "quality", "bitDepth", "maximumWidth", "maximumHeight", "dpi", "exifRetentionPolicy"] {
            XCTAssertTrue(optionsBlock.contains("\(field): \(field)"), "MacExportOptions must be built from the sheet's own \(field)")
        }
    }

    // MARK: - Entry point

    func testChoosingADestinationStartsTheBatchThroughTheViewModel() throws {
        let source = try Self.batchExportSheetSource()
        XCTAssertTrue(
            source.contains("model.presentBatchExportPanel(options: options)"),
            "choosing a destination must hand the collected options to the view model's batch export entry point"
        )
    }

    // MARK: - Live per-file status

    func testBatchExportSheetRendersOneRowPerQueueItem() throws {
        let source = try Self.batchExportSheetSource()
        XCTAssertTrue(
            source.contains("ForEach(model.batchExportItems"),
            "the sheet must render one row per item in the view model's live batch export queue"
        )
    }

    func testBatchExportSheetDistinguishesEveryQueueStatus() throws {
        let source = try Self.batchExportSheetSource()
        for status in ["case .pending", "case .running", "case .succeeded", "case .failed", "case .cancelled"] {
            XCTAssertTrue(
                source.contains(status),
                "the sheet must render each queue status distinctly, including \(status)"
            )
        }
    }

    /// Plan: never collapse a per-file failure into a generic success icon --
    /// the failed row must show its own (path-free) message.
    func testAFailedItemsOwnMessageIsShownNotAGenericSuccessLabel() throws {
        let source = try Self.batchExportSheetSource()
        XCTAssertTrue(
            source.contains("case .failed(let message)") || source.contains("case .failed(let message):"),
            "a failed item's own message must be extracted and shown, not discarded"
        )
    }

    // MARK: - Totals (must not fake all-PASS)

    func testBatchExportSheetShowsSucceededFailedAndCancelledTotals() throws {
        let source = try Self.batchExportSheetSource()
        for key in ["succeeded", "failed to export", "cancelled"] {
            XCTAssertTrue(
                source.contains("L10n.t(\"\(key)\")"),
                "the batch summary must report a \(key) count through localization, not just a blanket success message"
            )
        }
    }

    // MARK: - Cancel action

    func testBatchExportSheetOffersACancelActionWiredToTheViewModel() throws {
        let source = try Self.batchExportSheetSource()
        XCTAssertTrue(
            source.contains("model.cancelBatchExport()"),
            "the sheet must offer a cancel action that calls the view model's cancelBatchExport()"
        )
    }

    // MARK: - Close / report retention

    func testBatchExportSheetClosesThroughTheViewModelsDedicatedAction() throws {
        let source = try Self.batchExportSheetSource()
        XCTAssertTrue(
            source.contains("model.closeBatchExportSheet()"),
            "closing the sheet must go through closeBatchExportSheet(), which decides whether to retain a still-running report"
        )
    }

    // MARK: - Entry points wired into the rest of the app

    func testRootViewPresentsTheBatchExportSheet() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/RootView.swift")
        XCTAssertTrue(source.contains("model.isShowingBatchExportSheet"))
        XCTAssertTrue(source.contains("BatchExportSheet()"))
    }

    func testLibraryGridOffersABatchExportEntryPointGatedOnSelection() throws {
        let source = try Self.loadSource("Sources/LumaHarborApp/Views/LibraryGridView.swift")
        XCTAssertTrue(
            source.contains("model.isShowingBatchExportSheet = true"),
            "the grid must offer a way to open the batch export sheet"
        )
        XCTAssertTrue(
            source.contains("model.selectedPhotoIDs.isEmpty"),
            "the batch export entry point must be gated on selectedPhotoIDs, not always enabled"
        )
    }
}
