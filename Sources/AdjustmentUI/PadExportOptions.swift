import Foundation
import RawProcessingCore

/// iPad's export form state. It maps to the shared `ExportRequest`; the app
/// does not get a second encoder or render path because the controls live in
/// an iPad sheet.
public struct PadExportOptions: Equatable, Sendable {
    public var format: ExportFormat = .jpeg
    public var quality: Double = 0.9
    public var bitDepth: ExportBitDepth = .eightBit
    public var maximumDimension: Int?
    public var dpi: Double?
    public var exifRetentionPolicy: ExifRetentionPolicy = .preserveAll
    public var collisionPolicy: ExportCollisionPolicy = .increment

    public init() {}

    public var qualityPercentage: Double {
        get { quality * 100 }
        set { quality = min(max(newValue / 100, 0), 1) }
    }

    public mutating func setMaximumDimension(_ value: Int?) {
        guard let value else {
            maximumDimension = nil
            return
        }
        maximumDimension = min(max(value, 256), 100_000)
    }

    public mutating func setDPI(_ value: Double?) {
        guard let value else {
            dpi = nil
            return
        }
        dpi = min(max(value, 1), 2_400)
    }

    public func request(
        sourceURL: URL,
        adjustments: PhotoAdjustments,
        destinationDirectory: URL,
        baseFilename: String
    ) -> ExportRequest {
        ExportRequest(
            sourceURL: sourceURL,
            adjustments: adjustments,
            destinationDirectory: destinationDirectory,
            baseFilename: baseFilename,
            format: format,
            quality: quality,
            bitDepth: format.supportsBitDepthChoice ? bitDepth : .eightBit,
            maximumWidth: maximumDimension,
            maximumHeight: maximumDimension,
            dpi: dpi,
            exifRetentionPolicy: exifRetentionPolicy,
            collisionPolicy: collisionPolicy
        )
    }
}
