import Foundation

/// Incremental 11-row SSIM accumulator. It keeps only the rows needed for the
/// current vertical window; horizontal sums are built from reusable prefixes.
public struct SlidingWindowSSIMAccumulator {
    private struct Row {
        let lhs: [Double]
        let rhs: [Double]
    }

    private let width: Int
    private let height: Int
    private let radius: Int
    private var rows: [Int: Row] = [:]
    private var appendedRows = 0
    private var nextCenter = 0
    private var total = 0.0
    private var windowCount = 0

    public init(width: Int, height: Int, radius: Int = 5) throws {
        guard width > 0, height > 0, radius >= 0 else {
            throw ReferenceComparisonError.invalidDimensions
        }
        self.width = width
        self.height = height
        self.radius = radius
    }

    public mutating func append(lhs: [Double], rhs: [Double]) throws {
        guard lhs.count == width, rhs.count == width else {
            throw ReferenceComparisonError.sampleCountMismatch
        }
        guard appendedRows < height else {
            throw ReferenceComparisonError.invalidDimensions
        }
        rows[appendedRows] = Row(lhs: lhs, rhs: rhs)
        appendedRows += 1

        if appendedRows - 1 >= radius {
            try process(center: appendedRows - 1 - radius)
        }
    }

    public mutating func finish() throws -> Double {
        guard appendedRows == height else {
            throw ReferenceComparisonError.sampleCountMismatch
        }
        while nextCenter < height {
            try process(center: nextCenter)
        }
        guard windowCount > 0 else {
            throw ReferenceComparisonError.invalidDimensions
        }
        return min(1, max(-1, total / Double(windowCount)))
    }

    private mutating func process(center: Int) throws {
        guard center == nextCenter else {
            throw ReferenceComparisonError.invalidDimensions
        }
        let minY = max(0, center - radius)
        let maxY = min(height - 1, center + radius)
        guard minY <= maxY else {
            throw ReferenceComparisonError.invalidDimensions
        }

        var verticalLhs = [Double](repeating: 0, count: width)
        var verticalRhs = [Double](repeating: 0, count: width)
        var verticalLhsSquared = [Double](repeating: 0, count: width)
        var verticalRhsSquared = [Double](repeating: 0, count: width)
        var verticalProduct = [Double](repeating: 0, count: width)

        for rowIndex in minY...maxY {
            guard let row = rows[rowIndex] else {
                throw ReferenceComparisonError.sampleCountMismatch
            }
            for x in 0..<width {
                let lhs = row.lhs[x]
                let rhs = row.rhs[x]
                verticalLhs[x] += lhs
                verticalRhs[x] += rhs
                verticalLhsSquared[x] += lhs * lhs
                verticalRhsSquared[x] += rhs * rhs
                verticalProduct[x] += lhs * rhs
            }
        }

        let lhsPrefix = prefix(verticalLhs)
        let rhsPrefix = prefix(verticalRhs)
        let lhsSquaredPrefix = prefix(verticalLhsSquared)
        let rhsSquaredPrefix = prefix(verticalRhsSquared)
        let productPrefix = prefix(verticalProduct)
        let verticalCount = Double(maxY - minY + 1)

        for x in 0..<width {
            let minX = max(0, x - radius)
            let maxX = min(width - 1, x + radius)
            let horizontalCount = Double(maxX - minX + 1)
            let count = verticalCount * horizontalCount
            let lhsSum = rangeSum(lhsPrefix, minX, maxX)
            let rhsSum = rangeSum(rhsPrefix, minX, maxX)
            let lhsMean = lhsSum / count
            let rhsMean = rhsSum / count
            let lhsVariance = max(0, rangeSum(lhsSquaredPrefix, minX, maxX) / count - lhsMean * lhsMean)
            let rhsVariance = max(0, rangeSum(rhsSquaredPrefix, minX, maxX) / count - rhsMean * rhsMean)
            let covariance = rangeSum(productPrefix, minX, maxX) / count - lhsMean * rhsMean

            let numerator = (2 * lhsMean * rhsMean + 0.01 * 0.01)
                * (2 * covariance + 0.03 * 0.03)
            let denominator = (lhsMean * lhsMean + rhsMean * rhsMean + 0.01 * 0.01)
                * (lhsVariance + rhsVariance + 0.03 * 0.03)
            total += denominator == 0 ? 1 : numerator / denominator
            windowCount += 1
        }

        rows = rows.filter { $0.key >= max(0, center - radius) }
        nextCenter += 1
    }

    private func prefix(_ values: [Double]) -> [Double] {
        var result = [Double](repeating: 0, count: values.count + 1)
        for index in values.indices {
            result[index + 1] = result[index] + values[index]
        }
        return result
    }

    private func rangeSum(_ values: [Double], _ min: Int, _ max: Int) -> Double {
        values[max + 1] - values[min]
    }
}
