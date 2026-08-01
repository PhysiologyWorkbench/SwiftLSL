import Foundation

/// The byte order negotiated in the handshake (`src/util/endian.hpp:10-17`).
///
/// `liblsl` also defines 0 (portable), 1 and 2 (mixed float orders) and 2134 (PDP-11); of
/// those only 0 is ever seen, and it is remapped to native before it reaches here
/// (SCOPE.md §2.2).
public enum WireByteOrder: Int, Sendable, Hashable {
    case little = 1234
    case big = 4321

    public static let native: WireByteOrder = (1 as UInt16).littleEndian == 1 ? .little : .big

    /// The value `Byte-Order: 0` maps to — "portable", i.e. no conversion (SCOPE.md §2.2).
    public static let portable = 0
}

/// Sequential reader over a byte buffer.
///
/// A record whose bytes have not all arrived yet fails with `LSLError.incompleteRecord`;
/// the caller reads more and retries from the same offset. Records are small, so the
/// re-parse costs nothing worth avoiding.
public struct ByteReader: Sendable {
    private let data: Data
    /// Bytes consumed so far, from the start of the buffer.
    public private(set) var offset: Int

    public init(_ data: Data, offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    public var remaining: Int { data.count - offset }

    public mutating func readByte() throws -> UInt8 {
        guard remaining >= 1 else { throw LSLError.incompleteRecord }
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }

    public mutating func read(_ count: Int) throws -> Data {
        guard remaining >= count else { throw LSLError.incompleteRecord }
        let start = data.startIndex + offset
        offset += count
        return data[start..<(start + count)]
    }

    public mutating func readInteger<T: FixedWidthInteger>(
        _: T.Type, _ order: WireByteOrder
    ) throws -> T {
        let width = MemoryLayout<T>.size
        guard remaining >= width else { throw LSLError.incompleteRecord }
        let start = data.startIndex + offset
        var value: T = 0
        for step in 0..<width {
            let index = order == .little ? width - 1 - step : step
            value = (value &<< 8) | T(truncatingIfNeeded: data[start + index])
        }
        offset += width
        return value
    }

    public mutating func readDouble(_ order: WireByteOrder) throws -> Double {
        Double(bitPattern: try readInteger(UInt64.self, order))
    }

    public mutating func readFloat(_ order: WireByteOrder) throws -> Float {
        Float(bitPattern: try readInteger(UInt32.self, order))
    }
}

/// Sequential writer over a byte buffer.
public struct ByteWriter: Sendable {
    public private(set) var data = Data()

    public init() {}

    public mutating func writeByte(_ value: UInt8) {
        data.append(value)
    }

    public mutating func write(_ bytes: Data) {
        data.append(bytes)
    }

    public mutating func writeInteger<T: FixedWidthInteger>(_ value: T, _ order: WireByteOrder) {
        let ordered = order == .little ? value.littleEndian : value.bigEndian
        withUnsafeBytes(of: ordered) { data.append(contentsOf: $0) }
    }

    public mutating func writeDouble(_ value: Double, _ order: WireByteOrder) {
        writeInteger(value.bitPattern, order)
    }

    public mutating func writeFloat(_ value: Float, _ order: WireByteOrder) {
        writeInteger(value.bitPattern, order)
    }
}
