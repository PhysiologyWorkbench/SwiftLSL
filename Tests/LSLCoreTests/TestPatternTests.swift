import Foundation
import Testing

@testable import LSLCore

@Suite("Test patterns")
struct TestPatternTests {
    /// The generator must reproduce, bit for bit, what a real outlet sends — a mismatch
    /// drops the connection (SCOPE.md §2.2). These are the bytes a live liblsl 1.17.7
    /// outlet actually sent for a five-channel stream of each format.
    @Test(
        "Generated patterns match a live liblsl outlet's bytes",
        arguments: ChannelFormat.allCases.filter { $0 != .undefined }
    )
    func matchesCapturedTrace(format: ChannelFormat) throws {
        let fixtures = TestPatternFixtures.shared
        let codec = SampleCodec(format: format, channelCount: fixtures.channelCount)
        var reader = ByteReader(fixtures.bytes(format.wireName))

        for offset in TestPattern.offsets {
            let expected = try TestPattern.sample(
                format: format, channelCount: fixtures.channelCount, offset: offset)
            #expect(try codec.decode(from: &reader) == expected)
        }
        #expect(reader.remaining == 0, "the trace holds exactly two records")
    }

    @Test("Both patterns re-encode to the captured bytes")
    func reencodesToCapturedTrace() throws {
        let fixtures = TestPatternFixtures.shared
        for format in ChannelFormat.allCases where format != .undefined {
            let codec = SampleCodec(format: format, channelCount: fixtures.channelCount)
            var encoded = Data()
            for offset in TestPattern.offsets {
                encoded += codec.encode(
                    try TestPattern.sample(
                        format: format, channelCount: fixtures.channelCount, offset: offset))
            }
            #expect(encoded == fixtures.bytes(format.wireName), "format \(format.wireName)")
        }
    }

    @Test("Values follow the documented rule", arguments: [4, 2])
    func documentedValues(offset: Int) throws {
        // ±(k + offset + bias), even indices positive (SCOPE.md §2.2).
        #expect(
            try TestPattern.values(format: .float32, channelCount: 4, offset: offset)
                == .float32([
                    Float(offset), -Float(1 + offset), Float(2 + offset), -Float(3 + offset),
                ]))
        #expect(
            try TestPattern.values(format: .int8, channelCount: 4, offset: offset)
                == .int8([
                    Int8(offset + 1), Int8(-(2 + offset)), Int8(3 + offset), Int8(-(4 + offset)),
                ]))
        #expect(
            try TestPattern.values(format: .int64, channelCount: 3, offset: offset)
                == .int64([
                    2_147_483_649 + Int64(offset), -(2_147_483_650 + Int64(offset)),
                    2_147_483_651 + Int64(offset),
                ]))
    }

    @Test("String channels ignore the offset entirely")
    func stringPatternIgnoresOffset() throws {
        let expected = SampleValues.string(["10", "-11", "12", "-13"])
        #expect(try TestPattern.values(format: .string, channelCount: 4, offset: 4) == expected)
        #expect(try TestPattern.values(format: .string, channelCount: 4, offset: 2) == expected)
    }

    @Test("Integer patterns wrap modulo the format's maximum")
    func integerModulo() throws {
        // int8 with offset 4 has bias 1, so channel k holds ±((k + 5) % 127).
        guard case .int8(let values) = try TestPattern.values(
            format: .int8, channelCount: 130, offset: 4)
        else { Issue.record(); return }
        #expect(values[121] == -((121 + 5) % 127))
        #expect(values[122] == 0, "127 % 127 wraps to zero")
        #expect(values[123] == -1, "128 % 127 wraps to one, negated at an odd index")
        #expect(values[124] == 2)
    }

    @Test("Every pattern carries the fixed timestamp")
    func fixedTimestamp() throws {
        for format in ChannelFormat.allCases where format != .undefined {
            let sample = try TestPattern.sample(format: format, channelCount: 2, offset: 4)
            #expect(sample.timestamp == 123456.789)
        }
    }

    @Test("Patterns for both byte orders decode to the same values", arguments: [4, 2])
    func byteOrderIndependence(offset: Int) throws {
        for format in ChannelFormat.allCases where format != .undefined {
            let sample = try TestPattern.sample(format: format, channelCount: 7, offset: offset)
            for order in [WireByteOrder.little, .big] {
                let codec = SampleCodec(format: format, channelCount: 7, byteOrder: order)
                var reader = ByteReader(codec.encode(sample))
                #expect(try codec.decode(from: &reader) == sample)
            }
        }
    }

    @Test("An undefined format has no test pattern")
    func undefinedFormat() {
        #expect(throws: (any Error).self) {
            _ = try TestPattern.sample(format: .undefined, channelCount: 1, offset: 4)
        }
    }
}
