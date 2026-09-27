import Foundation
import XCTest
@testable import RawProcessingCore

final class DCPProfileParserTests: XCTestCase {
    func testParsesLittleEndianInlineASCIIAndShortTags() throws {
        let data = SyntheticDCPTIFF.make(
            byteOrder: .littleEndian,
            tags: [
                .ascii(50708, "Synthetic Camera"),
                .ascii(50936, "Synthetic Profile"),
                .unsignedShort(50938, [3, 2, 2])
            ]
        )

        let document = try DCPProfileParser().parse(data)

        XCTAssertEqual(document.byteOrder, .littleEndian)
        XCTAssertEqual(document.value(for: .init(rawValue: 50708)), .ascii("Synthetic Camera"))
        XCTAssertEqual(document.value(for: .init(rawValue: 50938)), .unsignedShort([3, 2, 2]))
    }

    func testParsesBigEndianOffsetASCIIAndRationalTags() throws {
        let data = SyntheticDCPTIFF.make(
            byteOrder: .bigEndian,
            tags: [
                .ascii(50936, "Big Endian Profile"),
                .rational(50778, [(23, 1)])
            ]
        )

        let document = try DCPProfileParser().parse(data)

        XCTAssertEqual(document.byteOrder, .bigEndian)
        XCTAssertEqual(document.value(for: .init(rawValue: 50936)), .ascii("Big Endian Profile"))
        XCTAssertEqual(
            document.value(for: .init(rawValue: 50778)),
            .rational([DCPRational(numerator: 23, denominator: 1)])
        )
    }

    func testRejectsTruncatedHeaderAndIFD() {
        XCTAssertThrowsError(try DCPProfileParser().parse(Data([0x49, 0x49, 0x2A])))
        XCTAssertThrowsError(try DCPProfileParser().parse(SyntheticDCPTIFF.truncatedIFD()))
    }

    func testRejectsInvalidOffsetAndCountOverflowBeforeReadingPayload() {
        XCTAssertThrowsError(try DCPProfileParser().parse(SyntheticDCPTIFF.invalidPayloadOffset()))
        XCTAssertThrowsError(try DCPProfileParser().parse(SyntheticDCPTIFF.overflowingCount()))
    }

    func testRejectsUnsupportedTypeAndUnterminatedASCII() {
        XCTAssertThrowsError(try DCPProfileParser().parse(SyntheticDCPTIFF.unsupportedType()))
        XCTAssertThrowsError(try DCPProfileParser().parse(SyntheticDCPTIFF.unterminatedASCII()))
    }

    func testRejectsNonFiniteFloatingPointValue() {
        XCTAssertThrowsError(try DCPProfileParser().parse(SyntheticDCPTIFF.nonFiniteFloat()))
    }

    func testRejectsConfiguredResourceLimitAndTooManyEntries() {
        XCTAssertThrowsError(
            try DCPProfileParser(maxBytes: 8).parse(Data(repeating: 0, count: 9))
        )
        XCTAssertThrowsError(
            try DCPProfileParser(maxEntries: 0).parse(SyntheticDCPTIFF.make(byteOrder: .littleEndian, tags: [.ascii(50936, "Profile")]))
        )
    }

    func testRejectsZeroRationalDenominatorAndDuplicateTag() {
        XCTAssertThrowsError(
            try DCPProfileParser().parse(
                SyntheticDCPTIFF.make(byteOrder: .littleEndian, tags: [.rational(50778, [(1, 0)])])
            )
        )
        XCTAssertThrowsError(
            try DCPProfileParser().parse(
                SyntheticDCPTIFF.make(
                    byteOrder: .littleEndian,
                    tags: [.ascii(50936, "A"), .ascii(50936, "B")]
                )
            )
        )
    }
}

private enum SyntheticDCPTag {
    case ascii(UInt16, String)
    case unsignedShort(UInt16, [UInt16])
    case rational(UInt16, [(UInt32, UInt32)])
    case float(UInt16, [Float32])
    case raw(UInt16, type: UInt16, count: UInt32, payload: [UInt8])
}

private enum SyntheticDCPTIFF {
    static func make(byteOrder: DCPByteOrder, tags: [SyntheticDCPTag]) -> Data {
        var data = Data(repeating: 0, count: 10 + (tags.count * 12) + 4)
        write16(UInt16(tags.count), at: 8, in: &data, byteOrder: byteOrder)
        var payload = Data()

        for (index, tag) in tags.enumerated() {
            let entryOffset = 10 + (index * 12)
            let encoded = encode(tag, byteOrder: byteOrder)
            write16(encoded.tag, at: entryOffset, in: &data, byteOrder: byteOrder)
            write16(encoded.type, at: entryOffset + 2, in: &data, byteOrder: byteOrder)
            write32(encoded.count, at: entryOffset + 4, in: &data, byteOrder: byteOrder)

            if encoded.bytes.count <= 4 {
                writeBytes(encoded.bytes + Array(repeating: 0, count: 4 - encoded.bytes.count), at: entryOffset + 8, in: &data)
            } else {
                let offset = UInt32(data.count + payload.count)
                write32(offset, at: entryOffset + 8, in: &data, byteOrder: byteOrder)
                payload.append(contentsOf: encoded.bytes)
            }
        }

        data.append(payload)
        data[0] = byteOrder == .littleEndian ? 0x49 : 0x4D
        data[1] = data[0]
        write16(42, at: 2, in: &data, byteOrder: byteOrder)
        write32(8, at: 4, in: &data, byteOrder: byteOrder)
        return data
    }

    static func truncatedIFD() -> Data {
        Data([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00, 0x01, 0x00])
    }

    static func invalidPayloadOffset() -> Data {
        var data = make(byteOrder: .littleEndian, tags: [.ascii(50936, "Profile")])
        write32(UInt32.max, at: 18, in: &data, byteOrder: .littleEndian)
        return data
    }

    static func overflowingCount() -> Data {
        make(byteOrder: .littleEndian, tags: [.raw(50938, type: 5, count: UInt32.max, payload: [])])
    }

    static func unsupportedType() -> Data {
        make(byteOrder: .littleEndian, tags: [.raw(50936, type: 13, count: 1, payload: [0, 0, 0, 0])])
    }

    static func unterminatedASCII() -> Data {
        make(byteOrder: .littleEndian, tags: [.raw(50936, type: 2, count: 3, payload: [65, 66, 67])])
    }

    static func nonFiniteFloat() -> Data {
        make(byteOrder: .littleEndian, tags: [.float(50730, [.infinity])])
    }

    private static func encode(_ tag: SyntheticDCPTag, byteOrder: DCPByteOrder) -> (tag: UInt16, type: UInt16, count: UInt32, bytes: [UInt8]) {
        switch tag {
        case let .ascii(id, value):
            return (id, 2, UInt32(value.utf8.count + 1), Array(value.utf8) + [0])
        case let .unsignedShort(id, values):
            return (id, 3, UInt32(values.count), values.flatMap { bytes16($0, byteOrder: byteOrder) })
        case let .rational(id, values):
            let bytes = values.flatMap { bytes32($0.0, byteOrder: byteOrder) + bytes32($0.1, byteOrder: byteOrder) }
            return (id, 5, UInt32(values.count), bytes)
        case let .float(id, values):
            let bytes = values.flatMap { value in
                withUnsafeBytes(of: value.bitPattern.bigEndian) { Array($0) }
            }
            let normalized = byteOrder == .littleEndian ? values.flatMap { bytes32($0.bitPattern, byteOrder: .littleEndian) } : bytes
            return (id, 11, UInt32(values.count), normalized)
        case let .raw(id, type, count, payload):
            return (id, type, count, payload)
        }
    }

    private static func bytes16(_ value: UInt16, byteOrder: DCPByteOrder) -> [UInt8] {
        byteOrder == .littleEndian
            ? [UInt8(value & 0xFF), UInt8(value >> 8)]
            : [UInt8(value >> 8), UInt8(value & 0xFF)]
    }

    private static func bytes32(_ value: UInt32, byteOrder: DCPByteOrder) -> [UInt8] {
        if byteOrder == .littleEndian {
            return [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)]
        }
        return [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    private static func write16(_ value: UInt16, at offset: Int, in data: inout Data, byteOrder: DCPByteOrder) {
        data.replaceSubrange(offset..<(offset + 2), with: bytes16(value, byteOrder: byteOrder))
    }

    private static func write32(_ value: UInt32, at offset: Int, in data: inout Data, byteOrder: DCPByteOrder) {
        data.replaceSubrange(offset..<(offset + 4), with: bytes32(value, byteOrder: byteOrder))
    }

    private static func writeBytes(_ bytes: [UInt8], at offset: Int, in data: inout Data) {
        data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }
}
