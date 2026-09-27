import Compression
import Foundation

public enum AdobeRGBTableCodecError: Swift.Error, Equatable, Sendable {
    case invalidBase85
    case invalidCompressedPayload
    case decompressionLimitExceeded
    case unsupportedVersion
    case invalidDimensions
    case invalidChannelCount
    case invalidUncompressedSize
    case malformedPayload
    case invalidFooter
    case invalidSample
}

public struct AdobeRGBTableCodec: Sendable {
    public struct Limits: Equatable, Sendable {
        public let maximumGridSize: Int
        public let maxUncompressedBytes: Int
        public let maxEncodedCharacters: Int

        public init(
            maximumGridSize: Int = 32,
            maxUncompressedBytes: Int = 64 * 1024 * 1024,
            maxEncodedCharacters: Int = 96 * 1024 * 1024
        ) {
            self.maximumGridSize = maximumGridSize
            self.maxUncompressedBytes = maxUncompressedBytes
            self.maxEncodedCharacters = maxEncodedCharacters
        }
    }

    private static let base85Alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-:+=^!/*?`'|()[]{}@%$#".utf8)
    private let limits: Limits

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    public func encode(_ table: AdobeRGBTable) throws -> String {
        return try base85Encode(encodePayload(table))
    }

    public func decode(_ encoded: String) throws -> AdobeRGBTable {
        guard !encoded.isEmpty, encoded.utf8.count <= limits.maxEncodedCharacters else {
            throw AdobeRGBTableCodecError.invalidBase85
        }
        return try decodePayload(base85Decode(encoded))
    }

    public func decodePayload(_ payload: Data) throws -> AdobeRGBTable {
        guard payload.count >= 5 else {
            throw AdobeRGBTableCodecError.invalidCompressedPayload
        }
        let expectedSize = Int(readUInt32LE(payload, offset: 0))
        guard expectedSize > 0 else {
            throw AdobeRGBTableCodecError.invalidUncompressedSize
        }
        guard expectedSize <= limits.maxUncompressedBytes else {
            throw AdobeRGBTableCodecError.decompressionLimitExceeded
        }
        let compressed = Data(payload.dropFirst(4))
        guard let uncompressed = decompress(compressed, expectedSize: expectedSize) else {
            throw AdobeRGBTableCodecError.invalidCompressedPayload
        }
        return try decodeUncompressedPayload(uncompressed)
    }

    public func encodePayload(_ table: AdobeRGBTable) throws -> Data {
        guard table.gridSize <= limits.maximumGridSize else {
            throw AdobeRGBTableCodecError.invalidDimensions
        }
        let uncompressed = try encodeUncompressedPayload(table)
        guard uncompressed.count <= limits.maxUncompressedBytes else {
            throw AdobeRGBTableCodecError.decompressionLimitExceeded
        }
        guard let compressed = compress(uncompressed) else {
            throw AdobeRGBTableCodecError.invalidCompressedPayload
        }
        var payload = Data()
        appendUInt32LE(UInt32(uncompressed.count), to: &payload)
        payload.append(compressed)
        return payload
    }

    func decodeUncompressedPayload(_ data: Data) throws -> AdobeRGBTable {
        guard data.count >= 16 else {
            throw AdobeRGBTableCodecError.malformedPayload
        }
        let version = readUInt32LE(data, offset: 0)
        guard version == 1, readUInt32LE(data, offset: 4) == 1 else {
            throw AdobeRGBTableCodecError.unsupportedVersion
        }
        guard readUInt32LE(data, offset: 8) == 3 else {
            throw AdobeRGBTableCodecError.invalidChannelCount
        }
        let gridSize = Int(readUInt32LE(data, offset: 12))
        guard (1...limits.maximumGridSize).contains(gridSize) else {
            throw AdobeRGBTableCodecError.invalidDimensions
        }
        let (square, squareOverflow) = gridSize.multipliedReportingOverflow(by: gridSize)
        let (cube, cubeOverflow) = square.multipliedReportingOverflow(by: gridSize)
        let (lutBytes, lutOverflow) = cube.multipliedReportingOverflow(by: 6)
        let (footerOffset, footerOverflow) = lutBytes.addingReportingOverflow(16)
        let (expectedSize, expectedOverflow) = footerOffset.addingReportingOverflow(28)
        guard !squareOverflow, !cubeOverflow, !lutOverflow, !footerOverflow, !expectedOverflow,
              data.count == expectedSize else {
            throw AdobeRGBTableCodecError.invalidUncompressedSize
        }

        var samples: [AdobeRGBTable.Sample] = []
        samples.reserveCapacity(cube)
        for index in 0..<cube {
            let redIndex = index / (gridSize * gridSize)
            let greenIndex = (index / gridSize) % gridSize
            let blueIndex = index % gridSize
            let offset = 16 + index * 6
            let red = reconstruct(readUInt16LE(data, offset: offset), identity: identityValue(redIndex, gridSize: gridSize))
            let green = reconstruct(readUInt16LE(data, offset: offset + 2), identity: identityValue(greenIndex, gridSize: gridSize))
            let blue = reconstruct(readUInt16LE(data, offset: offset + 4), identity: identityValue(blueIndex, gridSize: gridSize))
            samples.append(.init(red: red, green: green, blue: blue))
        }

        let colorPrimaries = readUInt32LE(data, offset: footerOffset)
        let gamma = readUInt32LE(data, offset: footerOffset + 4)
        let gamut = readUInt32LE(data, offset: footerOffset + 8)
        let minimumAmount = readDoubleLE(data, offset: footerOffset + 12)
        let maximumAmount = readDoubleLE(data, offset: footerOffset + 20)
        guard minimumAmount.isFinite, maximumAmount.isFinite, minimumAmount <= maximumAmount else {
            throw AdobeRGBTableCodecError.invalidFooter
        }
        return try AdobeRGBTable(
            gridSize: gridSize,
            samples: samples,
            colorPrimaries: colorPrimaries,
            gamma: gamma,
            gamut: gamut,
            minimumAmount: minimumAmount,
            maximumAmount: maximumAmount
        )
    }

    private func encodeUncompressedPayload(_ table: AdobeRGBTable) throws -> Data {
        var data = Data()
        appendUInt32LE(1, to: &data)
        appendUInt32LE(1, to: &data)
        appendUInt32LE(3, to: &data)
        appendUInt32LE(UInt32(table.gridSize), to: &data)
        for index in table.samples.indices {
            let redIndex = index / (table.gridSize * table.gridSize)
            let greenIndex = (index / table.gridSize) % table.gridSize
            let blueIndex = index % table.gridSize
            let sample = table.samples[index]
            appendUInt16LE(delta(sample.red, identity: identityValue(redIndex, gridSize: table.gridSize)), to: &data)
            appendUInt16LE(delta(sample.green, identity: identityValue(greenIndex, gridSize: table.gridSize)), to: &data)
            appendUInt16LE(delta(sample.blue, identity: identityValue(blueIndex, gridSize: table.gridSize)), to: &data)
        }
        appendUInt32LE(table.colorPrimaries, to: &data)
        appendUInt32LE(table.gamma, to: &data)
        appendUInt32LE(table.gamut, to: &data)
        appendDoubleLE(table.minimumAmount, to: &data)
        appendDoubleLE(table.maximumAmount, to: &data)
        return data
    }

    private func base85Encode(_ data: Data) throws -> String {
        let byteCount = data.count
        let outputCount = (byteCount * 5 + 3) / 4
        var padded = data
        let paddingCount = (4 - (byteCount % 4)) % 4
        padded.append(contentsOf: repeatElement(0, count: paddingCount))
        var output = [UInt8]()
        output.reserveCapacity(outputCount)
        for offset in stride(from: 0, to: padded.count, by: 4) {
            var value = readUInt32LE(padded, offset: offset)
            for _ in 0..<5 {
                output.append(Self.base85Alphabet[Int(value % 85)])
                value /= 85
            }
        }
        return String(decoding: output.prefix(outputCount), as: UTF8.self)
    }

    private func base85Decode(_ encoded: String) throws -> Data {
        let bytes = Array(encoded.utf8)
        guard bytes.count % 5 != 1 else {
            throw AdobeRGBTableCodecError.invalidBase85
        }
        var reverse = [UInt8: UInt32](minimumCapacity: 85)
        for (index, byte) in Self.base85Alphabet.enumerated() {
            reverse[byte] = UInt32(index)
        }
        guard bytes.allSatisfy({ reverse[$0] != nil }) else {
            throw AdobeRGBTableCodecError.invalidBase85
        }
        var padded = bytes
        let paddingCount = (5 - (bytes.count % 5)) % 5
        padded.append(contentsOf: repeatElement(Self.base85Alphabet[0], count: paddingCount))
        var output = Data()
        output.reserveCapacity((bytes.count * 4) / 5)
        for offset in stride(from: 0, to: padded.count, by: 5) {
            var value: UInt64 = 0
            var multiplier: UInt64 = 1
            for index in 0..<5 {
                value += UInt64(reverse[padded[offset + index]]!) * multiplier
                multiplier *= 85
            }
            guard value <= UInt64(UInt32.max) else {
                throw AdobeRGBTableCodecError.invalidBase85
            }
            appendUInt32LE(UInt32(value), to: &output)
        }
        let byteCount = (bytes.count * 4) / 5
        return Data(output.prefix(byteCount))
    }

    private func compress(_ data: Data) -> Data? {
        let (capacity, overflow) = data.count.addingReportingOverflow(data.count / 1_000)
        guard !overflow, capacity <= Int.max - 64 else { return nil }
        let outputCapacity = capacity + 64
        var output = Data(count: outputCapacity)
        let count = output.withUnsafeMutableBytes { outputBuffer in
            data.withUnsafeBytes { inputBuffer in
                compression_encode_buffer(
                    outputBuffer.bindMemory(to: UInt8.self).baseAddress!, outputCapacity,
                    inputBuffer.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard count > 0 else { return nil }
        output.count = count
        return output
    }

    private func decompress(_ data: Data, expectedSize: Int) -> Data? {
        var output = Data(count: expectedSize)
        let count = output.withUnsafeMutableBytes { outputBuffer in
            data.withUnsafeBytes { inputBuffer in
                compression_decode_buffer(
                    outputBuffer.bindMemory(to: UInt8.self).baseAddress!, expectedSize,
                    inputBuffer.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard count == expectedSize else { return nil }
        return output
    }

    private func identityValue(_ index: Int, gridSize: Int) -> UInt16 {
        guard gridSize > 1 else { return 0 }
        let denominator = gridSize - 1
        return UInt16((index * 65_535 + (denominator >> 1)) / denominator)
    }

    private func delta(_ value: UInt16, identity: UInt16) -> UInt16 {
        UInt16(truncatingIfNeeded: Int(value) - Int(identity))
    }

    private func reconstruct(_ value: UInt16, identity: UInt16) -> UInt16 {
        UInt16(truncatingIfNeeded: Int(value) + Int(identity))
    }

    private func readUInt16LE(_ data: Data, offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }

    private func readDoubleLE(_ data: Data, offset: Int) -> Double {
        Double(bitPattern: UInt64(data[offset]) | (UInt64(data[offset + 1]) << 8) | (UInt64(data[offset + 2]) << 16) | (UInt64(data[offset + 3]) << 24) | (UInt64(data[offset + 4]) << 32) | (UInt64(data[offset + 5]) << 40) | (UInt64(data[offset + 6]) << 48) | (UInt64(data[offset + 7]) << 56))
    }

    private func appendUInt16LE(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private func appendDoubleLE(_ value: Double, to data: inout Data) {
        appendUInt64LE(value.bitPattern, to: &data)
    }

    private func appendUInt64LE(_ value: UInt64, to data: inout Data) {
        for shift in stride(from: 0, through: 56, by: 8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }
}
