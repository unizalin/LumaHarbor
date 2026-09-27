import Foundation

public enum DCPByteOrder: String, Codable, Equatable, Sendable {
    case littleEndian
    case bigEndian
}

public struct DCPRational: Codable, Equatable, Sendable {
    public let numerator: UInt32
    public let denominator: UInt32

    public init(numerator: UInt32, denominator: UInt32) {
        self.numerator = numerator
        self.denominator = denominator
    }
}

public struct DCPSignedRational: Codable, Equatable, Sendable {
    public let numerator: Int32
    public let denominator: Int32

    public init(numerator: Int32, denominator: Int32) {
        self.numerator = numerator
        self.denominator = denominator
    }
}

public struct DCPTagID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }
}

public enum DCPProfileTag {
    public static let uniqueCameraModel = DCPTagID(rawValue: 50708)
    public static let profileName = DCPTagID(rawValue: 50936)
    public static let calibrationIlluminant1 = DCPTagID(rawValue: 50778)
    public static let calibrationIlluminant2 = DCPTagID(rawValue: 50779)
    public static let colorMatrix1 = DCPTagID(rawValue: 50721)
    public static let colorMatrix2 = DCPTagID(rawValue: 50722)
    public static let forwardMatrix1 = DCPTagID(rawValue: 50964)
    public static let forwardMatrix2 = DCPTagID(rawValue: 50965)
    public static let profileHueSatMapDims = DCPTagID(rawValue: 50938)
    public static let profileHueSatMapData1 = DCPTagID(rawValue: 50939)
    public static let profileHueSatMapData2 = DCPTagID(rawValue: 50940)
    public static let profileLookTableDims = DCPTagID(rawValue: 50981)
    public static let profileLookTableData = DCPTagID(rawValue: 50982)
    public static let profileToneCurve = DCPTagID(rawValue: 50941)
}

public enum DCPTagValue: Codable, Equatable, Sendable {
    case ascii(String)
    case unsignedShort([UInt16])
    case unsignedLong([UInt32])
    case rational([DCPRational])
    case signedRational([DCPSignedRational])
    case float([Float32])
    case double([Float64])

    private enum CodingKeys: String, CodingKey {
        case kind
        case values
    }

    private enum Kind: String, Codable {
        case ascii
        case unsignedShort
        case unsignedLong
        case rational
        case signedRational
        case float
        case double
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .ascii(value):
            try container.encode(Kind.ascii, forKey: .kind)
            try container.encode(value, forKey: .values)
        case let .unsignedShort(value):
            try container.encode(Kind.unsignedShort, forKey: .kind)
            try container.encode(value, forKey: .values)
        case let .unsignedLong(value):
            try container.encode(Kind.unsignedLong, forKey: .kind)
            try container.encode(value, forKey: .values)
        case let .rational(value):
            try container.encode(Kind.rational, forKey: .kind)
            try container.encode(value, forKey: .values)
        case let .signedRational(value):
            try container.encode(Kind.signedRational, forKey: .kind)
            try container.encode(value, forKey: .values)
        case let .float(value):
            try container.encode(Kind.float, forKey: .kind)
            try container.encode(value.map(Double.init), forKey: .values)
        case let .double(value):
            try container.encode(Kind.double, forKey: .kind)
            try container.encode(value, forKey: .values)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .ascii:
            self = .ascii(try container.decode(String.self, forKey: .values))
        case .unsignedShort:
            self = .unsignedShort(try container.decode([UInt16].self, forKey: .values))
        case .unsignedLong:
            self = .unsignedLong(try container.decode([UInt32].self, forKey: .values))
        case .rational:
            self = .rational(try container.decode([DCPRational].self, forKey: .values))
        case .signedRational:
            self = .signedRational(try container.decode([DCPSignedRational].self, forKey: .values))
        case .float:
            self = .float(try container.decode([Double].self, forKey: .values).map(Float32.init))
        case .double:
            self = .double(try container.decode([Double].self, forKey: .values))
        }
    }
}

public struct DCPProfileDocument: Equatable, Sendable {
    public let byteOrder: DCPByteOrder
    public let tags: [DCPTagID: DCPTagValue]

    public init(byteOrder: DCPByteOrder, tags: [DCPTagID: DCPTagValue]) {
        self.byteOrder = byteOrder
        self.tags = tags
    }

    public func value(for id: DCPTagID) -> DCPTagValue? {
        tags[id]
    }
}
