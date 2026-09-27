import Foundation

public struct DCPProfileParser: Sendable {
    public enum Error: Swift.Error, Equatable, Sendable {
        case dataTooShort
        case invalidByteOrder
        case invalidMagic
        case invalidIFDOffset
        case truncatedIFD
        case invalidType
        case invalidValueOffset
        case countOverflow
        case unsupportedValueEncoding
        case unterminatedASCII
        case nonFiniteNumber
        case duplicateTag
        case resourceLimitExceeded
    }

    private let maxBytes: Int
    private let maxEntries: Int

    public init(maxBytes: Int = 64 * 1024 * 1024, maxEntries: Int = 4_096) {
        self.maxBytes = maxBytes
        self.maxEntries = maxEntries
    }

    public func parse(_ data: Data) throws -> DCPProfileDocument {
        guard data.count <= maxBytes else { throw Error.resourceLimitExceeded }
        guard data.count >= 8 else { throw Error.dataTooShort }

        let byteOrder: DCPByteOrder
        switch (data[0], data[1]) {
        case (0x49, 0x49): byteOrder = .littleEndian
        case (0x4D, 0x4D): byteOrder = .bigEndian
        default: throw Error.invalidByteOrder
        }

        guard readUInt16(in: data, at: 2, byteOrder: byteOrder) == 42 else {
            throw Error.invalidMagic
        }
        let ifdOffset = try checkedInt(readUInt32(in: data, at: 4, byteOrder: byteOrder))
        guard ifdOffset >= 8, ifdOffset <= data.count - 2 else {
            throw Error.invalidIFDOffset
        }

        let entryCount = Int(readUInt16(in: data, at: ifdOffset, byteOrder: byteOrder))
        guard entryCount <= maxEntries else { throw Error.resourceLimitExceeded }
        let entriesStart = try checkedAdd(ifdOffset, 2)
        let entriesBytes = try checkedMultiply(entryCount, 12)
        let entriesEnd = try checkedAdd(entriesStart, entriesBytes)
        let nextIFDEnd = try checkedAdd(entriesEnd, 4)
        guard nextIFDEnd <= data.count else { throw Error.truncatedIFD }

        var tags: [DCPTagID: DCPTagValue] = [:]
        for index in 0..<entryCount {
            let entryOffset = try checkedAdd(entriesStart, try checkedMultiply(index, 12))
            let tag = DCPTagID(rawValue: readUInt16(in: data, at: entryOffset, byteOrder: byteOrder))
            guard tags[tag] == nil else { throw Error.duplicateTag }
            let type = readUInt16(in: data, at: entryOffset + 2, byteOrder: byteOrder)
            let count = readUInt32(in: data, at: entryOffset + 4, byteOrder: byteOrder)
            let value = try decodeValue(
                data: data,
                type: type,
                count: count,
                entryOffset: entryOffset,
                byteOrder: byteOrder
            )
            tags[tag] = value
        }

        return DCPProfileDocument(byteOrder: byteOrder, tags: tags)
    }

    private func decodeValue(
        data: Data,
        type: UInt16,
        count: UInt32,
        entryOffset: Int,
        byteOrder: DCPByteOrder
    ) throws -> DCPTagValue {
        let elementSize: Int
        switch type {
        case 2: elementSize = 1
        case 3: elementSize = 2
        case 4, 9, 11: elementSize = 4
        case 5, 10: elementSize = 8
        case 12: elementSize = 8
        default: throw Error.invalidType
        }

        let countInt = try checkedInt(count)
        let payloadSize = try checkedMultiply(countInt, elementSize)
        let payload: Data
        if payloadSize <= 4 {
            let inlineStart = try checkedAdd(entryOffset, 8)
            let inlineEnd = try checkedAdd(inlineStart, payloadSize)
            guard inlineEnd <= data.count else { throw Error.truncatedIFD }
            payload = data.subdata(in: inlineStart..<inlineEnd)
        } else {
            let offsetValue = readUInt32(in: data, at: entryOffset + 8, byteOrder: byteOrder)
            let offset = try checkedInt(offsetValue)
            let end = try checkedAdd(offset, payloadSize)
            guard offset >= 0, end <= data.count else { throw Error.invalidValueOffset }
            payload = data.subdata(in: offset..<end)
        }

        switch type {
        case 2:
            guard payload.last == 0 else { throw Error.unterminatedASCII }
            let bytes = payload.dropLast()
            guard let value = String(bytes: bytes, encoding: .utf8) else {
                throw Error.unsupportedValueEncoding
            }
            return .ascii(value)
        case 3:
            return .unsignedShort(try decodeUInt16Array(payload, count: countInt, byteOrder: byteOrder))
        case 4:
            return .unsignedLong(try decodeUInt32Array(payload, count: countInt, byteOrder: byteOrder))
        case 5:
            return .rational(try decodeRationalArray(payload, count: countInt, byteOrder: byteOrder))
        case 10:
            return .signedRational(try decodeSignedRationalArray(payload, count: countInt, byteOrder: byteOrder))
        case 11:
            let values = try decodeUInt32Array(payload, count: countInt, byteOrder: byteOrder).map(Float32.init(bitPattern:))
            guard values.allSatisfy(\.isFinite) else { throw Error.nonFiniteNumber }
            return .float(values)
        case 12:
            let values = try decodeUInt64Array(payload, count: countInt, byteOrder: byteOrder).map(Float64.init(bitPattern:))
            guard values.allSatisfy(\.isFinite) else { throw Error.nonFiniteNumber }
            return .double(values)
        default:
            throw Error.invalidType
        }
    }

    private func decodeUInt16Array(_ data: Data, count: Int, byteOrder: DCPByteOrder) throws -> [UInt16] {
        let expectedBytes = try checkedMultiply(count, 2)
        guard data.count == expectedBytes else { throw Error.truncatedIFD }
        return (0..<count).map { index in
            readUInt16(in: data, at: index * 2, byteOrder: byteOrder)
        }
    }

    private func decodeUInt32Array(_ data: Data, count: Int, byteOrder: DCPByteOrder) throws -> [UInt32] {
        let expectedBytes = try checkedMultiply(count, 4)
        guard data.count == expectedBytes else { throw Error.truncatedIFD }
        return (0..<count).map { index in
            readUInt32(in: data, at: index * 4, byteOrder: byteOrder)
        }
    }

    private func decodeUInt64Array(_ data: Data, count: Int, byteOrder: DCPByteOrder) throws -> [UInt64] {
        let expectedBytes = try checkedMultiply(count, 8)
        guard data.count == expectedBytes else { throw Error.truncatedIFD }
        return (0..<count).map { index in
            readUInt64(in: data, at: index * 8, byteOrder: byteOrder)
        }
    }

    private func decodeRationalArray(_ data: Data, count: Int, byteOrder: DCPByteOrder) throws -> [DCPRational] {
        let expectedBytes = try checkedMultiply(count, 8)
        guard data.count == expectedBytes else { throw Error.truncatedIFD }
        return try (0..<count).map { index in
            let offset = index * 8
            let denominator = readUInt32(in: data, at: offset + 4, byteOrder: byteOrder)
            guard denominator != 0 else { throw Error.nonFiniteNumber }
            return DCPRational(
                numerator: readUInt32(in: data, at: offset, byteOrder: byteOrder),
                denominator: denominator
            )
        }
    }

    private func decodeSignedRationalArray(_ data: Data, count: Int, byteOrder: DCPByteOrder) throws -> [DCPSignedRational] {
        let expectedBytes = try checkedMultiply(count, 8)
        guard data.count == expectedBytes else { throw Error.truncatedIFD }
        return try (0..<count).map { index in
            let offset = index * 8
            let denominator = Int32(bitPattern: readUInt32(in: data, at: offset + 4, byteOrder: byteOrder))
            guard denominator != 0 else { throw Error.nonFiniteNumber }
            return DCPSignedRational(
                numerator: Int32(bitPattern: readUInt32(in: data, at: offset, byteOrder: byteOrder)),
                denominator: denominator
            )
        }
    }

    private func checkedInt(_ value: UInt32) throws -> Int {
        guard let converted = Int(exactly: value) else { throw Error.countOverflow }
        return converted
    }

    private func checkedAdd(_ lhs: Int, _ rhs: Int) throws -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        guard !result.overflow else {
            throw Error.countOverflow
        }
        return result.partialValue
    }

    private func checkedMultiply(_ lhs: Int, _ rhs: Int) throws -> Int {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        guard !result.overflow else { throw Error.countOverflow }
        return result.partialValue
    }

    private func readUInt16(in data: Data, at offset: Int, byteOrder: DCPByteOrder) -> UInt16 {
        let a = UInt16(data[offset])
        let b = UInt16(data[offset + 1])
        return byteOrder == .littleEndian ? a | (b << 8) : (a << 8) | b
    }

    private func readUInt32(in data: Data, at offset: Int, byteOrder: DCPByteOrder) -> UInt32 {
        let a = UInt32(readUInt16(in: data, at: offset, byteOrder: byteOrder))
        let b = UInt32(readUInt16(in: data, at: offset + 2, byteOrder: byteOrder))
        return byteOrder == .littleEndian ? a | (b << 16) : (a << 16) | b
    }

    private func readUInt64(in data: Data, at offset: Int, byteOrder: DCPByteOrder) -> UInt64 {
        let low = UInt64(readUInt32(in: data, at: offset, byteOrder: byteOrder))
        let high = UInt64(readUInt32(in: data, at: offset + 4, byteOrder: byteOrder))
        return byteOrder == .littleEndian ? low | (high << 32) : (low << 32) | high
    }
}
