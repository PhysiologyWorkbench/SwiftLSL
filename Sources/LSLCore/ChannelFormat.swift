/// The sample value type of a stream.
///
/// Raw values are the ordinals used by `liblsl`; note they are *not* in the same order as
/// the readable `channel_format` tokens (SCOPE.md §2.4).
public enum ChannelFormat: Int32, Sendable, Hashable, CaseIterable {
    case undefined = 0
    case float32 = 1
    case double64 = 2
    case string = 3
    case int32 = 4
    case int16 = 5
    case int8 = 6
    case int64 = 7

    /// Bytes per channel value as declared in the `Value-Size` handshake header; 0 for
    /// `string`, whose values are length-prefixed (`stream_info_impl::channel_bytes`).
    public var valueSize: Int {
        switch self {
        case .undefined, .string: 0
        case .float32, .int32: 4
        case .double64, .int64: 8
        case .int16: 2
        case .int8: 1
        }
    }

    /// The `<channel_format>` token in StreamInfo XML (SCOPE.md §2.4).
    public var wireName: String {
        switch self {
        case .undefined: "undefined"
        case .float32: "float32"
        case .double64: "double64"
        case .string: "string"
        case .int32: "int32"
        case .int16: "int16"
        case .int8: "int8"
        case .int64: "int64"
        }
    }

    public init?(wireName: String) {
        guard let match = Self.allCases.first(where: { $0.wireName == wireName }) else {
            return nil
        }
        self = match
    }

    /// Whether this format has subnormal values, i.e. what the inlet reports in
    /// `Supports-Subnormals` (`format_subnormal` at `src/sample.h:26-29`).
    public var hasSubnormals: Bool {
        self == .float32 || self == .double64
    }

    /// Whether a peer's `Byte-Order` value is usable for this format.
    ///
    /// `liblsl` waives the check only when the in-memory value width is one byte, which is
    /// true of `int8` alone — for `string` the width it tests is `sizeof(std::string)`, so
    /// string streams *do* require a real byte order, because the length prefixes are
    /// themselves byte-swapped (`src/sample.h:22-23`, `src/util/endian.hpp:23-31`).
    public func canConvertByteOrder(_ value: Int) -> Bool {
        self == .int8 || value == WireByteOrder.little.rawValue
            || value == WireByteOrder.big.rawValue
    }
}
