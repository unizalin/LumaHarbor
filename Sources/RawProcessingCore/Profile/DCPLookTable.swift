import Foundation

public struct DCPLookTable: Equatable, Sendable {
    private let grid: DCPTableGrid

    public init(dimensions: DCPTableDimensions, samples: [DCPHueSatSample]) throws {
        grid = try DCPTableGrid(dimensions: dimensions, samples: samples)
    }

    public init(document: DCPProfileDocument) throws {
        grid = try DCPTableGrid(
            document: document,
            dimensionsTag: DCPProfileTag.profileLookTableDims,
            dataTag: DCPProfileTag.profileLookTableData
        )
    }

    public func sample(hue: Double, saturation: Double, value: Double) -> DCPHueSatSample {
        grid.sample(hue: hue, saturation: saturation, value: value)
    }

    public func apply(to rgb: [Double]) throws -> [Double] {
        try grid.apply(to: rgb)
    }

    public static func blend(
        _ first: DCPLookTable,
        _ second: DCPLookTable,
        weight: Double
    ) throws -> DCPLookTable {
        try DCPLookTable(grid: first.grid.blended(with: second.grid, weight: weight))
    }

    private init(grid: DCPTableGrid) throws {
        self.grid = grid
    }
}
