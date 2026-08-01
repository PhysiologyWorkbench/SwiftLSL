import Foundation

/// The protocol-1.10 sample record codec (SCOPE.md §2.3, `src/sample.cpp:189-282`).
///
/// A record is a tag byte, an optional `f64` timestamp, then the channel values tightly
/// packed. There is no framing, no length prefix and no sample count: the transport reads
/// a flat sequence of these.
public struct SampleCodec: Sendable {
    /// 1 — deduce the timestamp from the previous one.
    public static let tagDeducedTimestamp: UInt8 = 1
    /// 2 — an `f64` timestamp follows.
    public static let tagTransmittedTimestamp: UInt8 = 2

    public let format: ChannelFormat
    public let channelCount: Int
    public let byteOrder: WireByteOrder
    /// Negotiated via `Suppress-Subnormals`; flushes subnormal floats to signed zero
    /// after decoding (`src/sample.cpp:267-280`).
    public let suppressSubnormals: Bool

    public init(
        format: ChannelFormat,
        channelCount: Int,
        byteOrder: WireByteOrder = .native,
        suppressSubnormals: Bool = false
    ) {
        self.format = format
        self.channelCount = channelCount
        self.byteOrder = byteOrder
        self.suppressSubnormals = suppressSubnormals
    }

    // MARK: - Decoding

    /// Decodes one record, leaving `reader` positioned after it. Throws
    /// `LSLError.incompleteRecord` without consuming anything usable if the buffer is
    /// short — retry from the same offset once more bytes have arrived.
    public func decode(from reader: inout ByteReader) throws -> SampleRecord {
        var cursor = reader
        let tag = try cursor.readByte()
        let timestamp: Double?
        switch tag {
        case Self.tagDeducedTimestamp:
            timestamp = nil
        case Self.tagTransmittedTimestamp:
            timestamp = try cursor.readDouble(byteOrder)
        default:
            throw LSLError.malformedMessage("unknown sample tag \(tag)")
        }
        let values = try decodeValues(from: &cursor)
        reader = cursor
        return SampleRecord(timestamp: timestamp, values: values)
    }

    private func decodeValues(from reader: inout ByteReader) throws -> SampleValues {
        switch format {
        case .float32:
            var values = [Float]()
            values.reserveCapacity(channelCount)
            for _ in 0..<channelCount {
                values.append(try reader.readFloat(byteOrder))
            }
            return .float32(suppressSubnormals ? values.map(Self.flushSubnormal) : values)
        case .double64:
            var values = [Double]()
            values.reserveCapacity(channelCount)
            for _ in 0..<channelCount {
                values.append(try reader.readDouble(byteOrder))
            }
            return .double64(suppressSubnormals ? values.map(Self.flushSubnormal) : values)
        case .int8:
            var values = [Int8]()
            values.reserveCapacity(channelCount)
            for _ in 0..<channelCount {
                values.append(Int8(bitPattern: try reader.readByte()))
            }
            return .int8(values)
        case .int16:
            var values = [Int16]()
            values.reserveCapacity(channelCount)
            for _ in 0..<channelCount {
                values.append(try reader.readInteger(Int16.self, byteOrder))
            }
            return .int16(values)
        case .int32:
            var values = [Int32]()
            values.reserveCapacity(channelCount)
            for _ in 0..<channelCount {
                values.append(try reader.readInteger(Int32.self, byteOrder))
            }
            return .int32(values)
        case .int64:
            var values = [Int64]()
            values.reserveCapacity(channelCount)
            for _ in 0..<channelCount {
                values.append(try reader.readInteger(Int64.self, byteOrder))
            }
            return .int64(values)
        case .string:
            var values = [String]()
            values.reserveCapacity(channelCount)
            for _ in 0..<channelCount {
                let length = try decodeStringLength(from: &reader)
                values.append(String(decoding: try reader.read(length), as: UTF8.self))
            }
            return .string(values)
        case .undefined:
            throw LSLError.malformedMessage("cannot decode samples of an undefined format")
        }
    }

    /// A string length is a width byte (1, 2, 4 or 8) followed by the length in that
    /// width — not a plain varint. The writer never emits width 2; the reader accepts it
    /// (`src/sample.cpp:199-216`, `240-261`).
    private func decodeStringLength(from reader: inout ByteReader) throws -> Int {
        let width = try reader.readByte()
        switch width {
        case 1: return Int(try reader.readByte())
        case 2: return Int(try reader.readInteger(UInt16.self, byteOrder))
        case 4: return Int(try reader.readInteger(UInt32.self, byteOrder))
        case 8:
            let length = try reader.readInteger(UInt64.self, byteOrder)
            guard length <= UInt64(Int.max) else {
                throw LSLError.malformedMessage("string length \(length) is out of range")
            }
            return Int(length)
        default:
            throw LSLError.malformedMessage("invalid varlen int width \(width)")
        }
    }

    // MARK: - Encoding

    public func encode(_ record: SampleRecord) -> Data {
        var writer = ByteWriter()
        if let timestamp = record.timestamp {
            writer.writeByte(Self.tagTransmittedTimestamp)
            writer.writeDouble(timestamp, byteOrder)
        } else {
            writer.writeByte(Self.tagDeducedTimestamp)
        }
        switch record.values {
        case .float32(let values):
            for value in values { writer.writeFloat(value, byteOrder) }
        case .double64(let values):
            for value in values { writer.writeDouble(value, byteOrder) }
        case .int8(let values):
            for value in values { writer.writeByte(UInt8(bitPattern: value)) }
        case .int16(let values):
            for value in values { writer.writeInteger(value, byteOrder) }
        case .int32(let values):
            for value in values { writer.writeInteger(value, byteOrder) }
        case .int64(let values):
            for value in values { writer.writeInteger(value, byteOrder) }
        case .string(let values):
            for value in values {
                let bytes = Data(value.utf8)
                // Widths 1 and 4 only, matching the reference writer.
                if bytes.count <= 0xFF {
                    writer.writeByte(1)
                    writer.writeByte(UInt8(bytes.count))
                } else {
                    writer.writeByte(4)
                    writer.writeInteger(UInt32(bytes.count), byteOrder)
                }
                writer.write(bytes)
            }
        }
        return writer.data
    }

    // MARK: - Subnormals

    private static func flushSubnormal(_ value: Float) -> Float {
        let bits = value.bitPattern
        guard bits != 0, bits & 0x7fff_ffff <= 0x007f_ffff else { return value }
        return Float(bitPattern: bits & 0x8000_0000)
    }

    private static func flushSubnormal(_ value: Double) -> Double {
        let bits = value.bitPattern
        guard bits != 0, bits & 0x7fff_ffff_ffff_ffff <= 0x000f_ffff_ffff_ffff else { return value }
        return Double(bitPattern: bits & 0x8000_0000_0000_0000)
    }
}
