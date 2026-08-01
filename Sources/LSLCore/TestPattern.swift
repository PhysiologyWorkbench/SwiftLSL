/// The two test-pattern samples an outlet sends immediately after the handshake.
///
/// The inlet generates them independently and compares for exact equality, timestamp
/// included; a mismatch means the protocol formats are incompatible and the connection
/// must be dropped (SCOPE.md §2.2, `src/sample.cpp:356-405`).
public enum TestPattern {
    /// Sent in this order (`src/tcp_server.cpp:698`).
    public static let offsets = [4, 2]

    /// Every test-pattern sample carries exactly this timestamp.
    public static let timestamp = 123456.789

    /// Added to `offset` before generation, per format. `string` ignores the offset.
    static func bias(for format: ChannelFormat) -> Int {
        switch format {
        case .float32: 0
        case .double64: 16_777_217
        case .int32: 65537
        case .int16: 257
        case .int8: 1
        case .int64: 2_147_483_649
        case .string, .undefined: 0
        }
    }

    public static func sample(
        format: ChannelFormat, channelCount: Int, offset: Int
    ) throws -> SampleRecord {
        SampleRecord(
            timestamp: timestamp,
            values: try values(format: format, channelCount: channelCount, offset: offset)
        )
    }

    static func values(
        format: ChannelFormat, channelCount: Int, offset: Int
    ) throws -> SampleValues {
        let total = offset + bias(for: format)
        switch format {
        case .float32:
            return .float32((0..<channelCount).map { signed(Float($0 + total), at: $0) })
        case .double64:
            return .double64((0..<channelCount).map { signed(Double($0 + total), at: $0) })
        case .int8:
            return .int8((0..<channelCount).map {
                signed(Int8(truncatingIfNeeded: ($0 + total) % Int(Int8.max)), at: $0)
            })
        case .int16:
            return .int16((0..<channelCount).map {
                signed(Int16(truncatingIfNeeded: ($0 + total) % Int(Int16.max)), at: $0)
            })
        case .int32:
            return .int32((0..<channelCount).map {
                signed(Int32(truncatingIfNeeded: ($0 + total) % Int(Int32.max)), at: $0)
            })
        case .int64:
            // int64 is generated without the modulo the other integer formats take.
            return .int64((0..<channelCount).map { signed(Int64($0 + total), at: $0) })
        case .string:
            return .string((0..<channelCount).map { String(($0 + 10) * ($0 % 2 == 0 ? 1 : -1)) })
        case .undefined:
            throw LSLError.malformedMessage("no test pattern exists for an undefined format")
        }
    }

    /// Even channel indices are positive, odd ones negated.
    private static func signed<T: SignedNumeric>(_ value: T, at index: Int) -> T {
        index % 2 == 0 ? value : -value
    }
}
