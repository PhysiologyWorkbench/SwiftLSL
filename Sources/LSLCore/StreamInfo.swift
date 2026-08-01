/// Everything an outlet advertises about a stream.
///
/// Field names and order on the wire are in SCOPE.md §2.4. The transport addresses and
/// ports are part of this struct — the inlet cannot connect without them — even though the
/// API sketch in SCOPE.md §7 omits them.
public struct StreamInfo: Sendable, Hashable {
    public let name: String
    public let type: String
    public let channelCount: Int
    /// 0 means irregular rate, in which case a deduced timestamp repeats its predecessor.
    public let nominalSampleRate: Double
    public let channelFormat: ChannelFormat
    public let sourceID: String
    public let uid: String
    public let sessionID: String
    public let hostname: String
    public let createdAt: Double
    /// 110, 100, … — the `<version>` field × 100 (SCOPE.md §2.4).
    public let protocolVersion: Int

    /// Filled in from the source address of a discovery reply when the outlet advertises
    /// none of its own (SCOPE.md §2.1), hence mutable.
    public var v4Address: String
    public let v4DataPort: UInt16
    public let v4ServicePort: UInt16
    public var v6Address: String
    public let v6DataPort: UInt16
    public let v6ServicePort: UInt16

    /// The `<desc>` subtree. Absent from a shortinfo reply; populated by
    /// `LSL:fullinfo` (SCOPE.md §2.4). Named `desc` rather than the sketch's
    /// `description`, which would silently satisfy `CustomStringConvertible`.
    public var desc: MetadataElement?

    public init(
        name: String,
        type: String = "",
        channelCount: Int,
        nominalSampleRate: Double = 0,
        channelFormat: ChannelFormat,
        sourceID: String = "",
        uid: String,
        sessionID: String = "default",
        hostname: String = "",
        createdAt: Double = 0,
        protocolVersion: Int = 110,
        v4Address: String = "",
        v4DataPort: UInt16 = 0,
        v4ServicePort: UInt16 = 0,
        v6Address: String = "",
        v6DataPort: UInt16 = 0,
        v6ServicePort: UInt16 = 0,
        desc: MetadataElement? = nil
    ) {
        self.name = name
        self.type = type
        self.channelCount = channelCount
        self.nominalSampleRate = nominalSampleRate
        self.channelFormat = channelFormat
        self.sourceID = sourceID
        self.uid = uid
        self.sessionID = sessionID
        self.hostname = hostname
        self.createdAt = createdAt
        self.protocolVersion = protocolVersion
        self.v4Address = v4Address
        self.v4DataPort = v4DataPort
        self.v4ServicePort = v4ServicePort
        self.v6Address = v6Address
        self.v6DataPort = v6DataPort
        self.v6ServicePort = v6ServicePort
        self.desc = desc
    }

    /// Bytes an outlet's `Value-Size` header must agree with, or it downgrades the
    /// connection to protocol 1.00 (`src/tcp_server.cpp:641-643`).
    public var channelBytes: Int { channelFormat.valueSize }
}
