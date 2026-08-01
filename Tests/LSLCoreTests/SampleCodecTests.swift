import Foundation
import Testing

@testable import LSLCore

@Suite("Sample record codec")
struct SampleCodecTests {
    static let numericFormats: [ChannelFormat] = [
        .float32, .double64, .int8, .int16, .int32, .int64,
    ]
    static let allFormats: [ChannelFormat] = numericFormats + [.string]
    static let byteOrders: [WireByteOrder] = [.little, .big]

    // MARK: - Hand-built vectors from SCOPE §2.3

    @Test("A transmitted timestamp is tag 2 followed by an f64")
    func transmittedTimestamp() throws {
        // tag 2, 123456.789 little-endian, one float32 channel holding 1.0
        let bytes = Data(hex: "02c976be9f0c24fe400000803f")
        let codec = SampleCodec(format: .float32, channelCount: 1)
        var reader = ByteReader(bytes)
        let record = try codec.decode(from: &reader)
        #expect(record.timestamp == 123456.789)
        #expect(record.values == .float32([1.0]))
        #expect(reader.remaining == 0)
    }

    @Test("A deduced timestamp is tag 1 with no timestamp field")
    func deducedTimestamp() throws {
        let bytes = Data(hex: "010000803f")
        let codec = SampleCodec(format: .float32, channelCount: 1)
        var reader = ByteReader(bytes)
        let record = try codec.decode(from: &reader)
        #expect(record.timestamp == nil)
        #expect(record.values == .float32([1.0]))
    }

    @Test("An unknown tag byte is rejected")
    func unknownTag() {
        var reader = ByteReader(Data(hex: "030000803f"))
        #expect(throws: LSLError.malformedMessage("unknown sample tag 3")) {
            _ = try SampleCodec(format: .float32, channelCount: 1).decode(from: &reader)
        }
    }

    @Test("String channels carry a width byte then the length in that width")
    func stringLengthWidths() throws {
        let codec = SampleCodec(format: .string, channelCount: 3)
        // width 1 / len 2 "ab", width 2 / len 1 "c", width 4 / len 0
        let bytes = Data(hex: "01" + "0102" + "6162" + "020100" + "63" + "0400000000")
        var reader = ByteReader(bytes)
        let record = try codec.decode(from: &reader)
        #expect(record.values == .string(["ab", "c", ""]))
    }

    @Test("An eight-byte string length is accepted")
    func stringLengthWidthEight() throws {
        let codec = SampleCodec(format: .string, channelCount: 1)
        var reader = ByteReader(Data(hex: "01" + "08" + "0200000000000000" + "6869"))
        #expect(try codec.decode(from: &reader).values == .string(["hi"]))
    }

    @Test("An invalid string length width is rejected")
    func invalidStringLengthWidth() {
        var reader = ByteReader(Data(hex: "0103"))
        #expect(throws: LSLError.malformedMessage("invalid varlen int width 3")) {
            _ = try SampleCodec(format: .string, channelCount: 1).decode(from: &reader)
        }
    }

    @Test("A short buffer leaves the reader untouched for a retry")
    func incompleteRecordDoesNotConsume() {
        let codec = SampleCodec(format: .double64, channelCount: 4)
        var reader = ByteReader(Data(hex: "02c976be9f0c24fe400000"))
        #expect(throws: LSLError.incompleteRecord) {
            _ = try codec.decode(from: &reader)
        }
        #expect(reader.offset == 0)
    }

    @Test("Records decode back to back from one buffer")
    func consecutiveRecords() throws {
        let codec = SampleCodec(format: .int16, channelCount: 2)
        var reader = ByteReader(Data(hex: "010100ffff" + "010200fdff"))
        #expect(try codec.decode(from: &reader).values == .int16([1, -1]))
        #expect(try codec.decode(from: &reader).values == .int16([2, -3]))
        #expect(reader.remaining == 0)
    }

    // MARK: - Byte order

    @Test("Big-endian numeric channels decode byte-swapped", arguments: numericFormats)
    func bigEndianDecode(format: ChannelFormat) throws {
        let values = try TestPattern.values(format: format, channelCount: 6, offset: 4)
        let record = SampleRecord(timestamp: 7.5, values: values)

        let little = SampleCodec(format: format, channelCount: 6, byteOrder: .little)
        let big = SampleCodec(format: format, channelCount: 6, byteOrder: .big)
        let littleBytes = little.encode(record)
        let bigBytes = big.encode(record)

        #expect(littleBytes.count == bigBytes.count)
        if format != .int8 {
            #expect(littleBytes != bigBytes, "byte order must change the encoding")
        }

        var reader = ByteReader(bigBytes)
        #expect(try big.decode(from: &reader) == record)
    }

    @Test("String length prefixes are byte-swapped too")
    func bigEndianStringLength() throws {
        let codec = SampleCodec(format: .string, channelCount: 1, byteOrder: .big)
        let long = String(repeating: "x", count: 300)
        var reader = ByteReader(codec.encode(SampleRecord(timestamp: nil, values: .string([long]))))
        #expect(try codec.decode(from: &reader).values == .string([long]))
        // width 4, then 300 = 0x0000012c big-endian
        #expect(codec.encode(SampleRecord(timestamp: nil, values: .string([long])))
            .prefix(6).hex == "01040000012c")
    }

    // MARK: - Round trips

    @Test(
        "Every format round-trips in both byte orders",
        arguments: allFormats, byteOrders
    )
    func roundTrip(format: ChannelFormat, order: WireByteOrder) throws {
        let codec = SampleCodec(format: format, channelCount: 8, byteOrder: order)
        for offset in [4, 2, 0, 1000] {
            for timestamp in [nil, 0.0, -1.0, 123456.789, Double.pi] as [Double?] {
                let record = SampleRecord(
                    timestamp: timestamp,
                    values: try TestPattern.values(
                        format: format, channelCount: 8, offset: offset)
                )
                var reader = ByteReader(codec.encode(record))
                #expect(try codec.decode(from: &reader) == record)
                #expect(reader.remaining == 0)
            }
        }
    }

    @Test("Extreme numeric values survive a round trip")
    func extremeValues() throws {
        let float = SampleRecord(
            timestamp: 1,
            values: .float32([.greatestFiniteMagnitude, -.greatestFiniteMagnitude, .infinity, 0, -0])
        )
        var reader = ByteReader(SampleCodec(format: .float32, channelCount: 5).encode(float))
        #expect(try SampleCodec(format: .float32, channelCount: 5).decode(from: &reader) == float)

        let integers = SampleRecord(timestamp: nil, values: .int64([.min, .max, 0, -1]))
        var intReader = ByteReader(SampleCodec(format: .int64, channelCount: 4).encode(integers))
        #expect(
            try SampleCodec(format: .int64, channelCount: 4).decode(from: &intReader) == integers)
    }

    // MARK: - Subnormals

    @Test("Subnormal float32 values are flushed to signed zero when negotiated")
    func subnormalFloat32() throws {
        let subnormal = Float(bitPattern: 0x0000_0001)
        let negative = Float(bitPattern: 0x8000_0001)
        let smallestNormal = Float(bitPattern: 0x0080_0000)
        let record = SampleRecord(
            timestamp: nil, values: .float32([subnormal, negative, smallestNormal, 0]))
        let bytes = SampleCodec(format: .float32, channelCount: 4).encode(record)

        var kept = ByteReader(bytes)
        #expect(try SampleCodec(format: .float32, channelCount: 4).decode(from: &kept) == record)

        var flushed = ByteReader(bytes)
        let suppressing = SampleCodec(
            format: .float32, channelCount: 4, suppressSubnormals: true)
        let decoded = try suppressing.decode(from: &flushed)
        guard case .float32(let values) = decoded.values else { Issue.record(); return }
        #expect(values[0].bitPattern == 0)
        #expect(values[1].bitPattern == 0x8000_0000)
        #expect(values[2] == smallestNormal)
        #expect(values[3].bitPattern == 0)
    }

    @Test("Subnormal double64 values are flushed to signed zero when negotiated")
    func subnormalDouble64() throws {
        let subnormal = Double(bitPattern: 0x0000_0000_0000_0001)
        let smallestNormal = Double(bitPattern: 0x0010_0000_0000_0000)
        let record = SampleRecord(timestamp: nil, values: .double64([subnormal, smallestNormal]))
        var reader = ByteReader(SampleCodec(format: .double64, channelCount: 2).encode(record))
        let decoded = try SampleCodec(
            format: .double64, channelCount: 2, suppressSubnormals: true
        ).decode(from: &reader)
        guard case .double64(let values) = decoded.values else { Issue.record(); return }
        #expect(values[0].bitPattern == 0)
        #expect(values[1] == smallestNormal)
    }

    // MARK: - Deduced timestamps

    @Test("A regular-rate stream advances deduced timestamps by 1/srate")
    func deduceRegularRate() {
        var deducer = TimestampDeducer(nominalSampleRate: 4)
        let values = SampleValues.int8([0])
        #expect(deducer.materialise(SampleRecord(timestamp: 100, values: values)).timestamp == 100)
        #expect(
            deducer.materialise(SampleRecord(timestamp: nil, values: values)).timestamp == 100.25)
        #expect(
            deducer.materialise(SampleRecord(timestamp: nil, values: values)).timestamp == 100.5)
        #expect(deducer.materialise(SampleRecord(timestamp: 7, values: values)).timestamp == 7)
        #expect(deducer.materialise(SampleRecord(timestamp: nil, values: values)).timestamp == 7.25)
    }

    @Test("An irregular-rate stream repeats the previous timestamp verbatim")
    func deduceIrregularRate() {
        var deducer = TimestampDeducer(nominalSampleRate: 0)
        let values = SampleValues.string(["x"])
        #expect(deducer.materialise(SampleRecord(timestamp: 5, values: values)).timestamp == 5)
        #expect(deducer.materialise(SampleRecord(timestamp: nil, values: values)).timestamp == 5)
        #expect(deducer.materialise(SampleRecord(timestamp: nil, values: values)).timestamp == 5)
    }

    @Test("A deduced first sample starts from zero, as liblsl does")
    func deduceFromSeed() {
        var deducer = TimestampDeducer(nominalSampleRate: 2)
        #expect(
            deducer.materialise(SampleRecord(timestamp: nil, values: .int8([0]))).timestamp == 0.5)
    }
}
