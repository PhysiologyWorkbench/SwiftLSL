import Foundation
import LSLCore

/// Knobs the inlet passes to the outlet in the handshake, plus its own recovery policy.
public struct InletConfiguration: Sendable {
    /// How much data the outlet may hold for us before it starts discarding.
    ///
    /// `Max-Buffer-Length` is in *samples* on the wire, but `liblsl` exposes seconds and
    /// converts with the nominal rate — 100 samples per second for an irregular stream
    /// (`src/stream_info_impl.cpp:calc_transport_buf_samples`,
    /// `src/lsl_inlet_c.cpp:17-22`). Its default is 360 s, so a 512 Hz stream asks for
    /// 184320 samples; asking for 360 samples flat would make any burst lossy. 0 makes
    /// the outlet send the header and then stop (`src/tcp_server.cpp:730`).
    public var maxBuffered: Duration = .seconds(360)
    /// `Max-Chunk-Length`; 0 leaves the batching to the outlet. Chunking is a sender-side
    /// write optimisation and has no representation on the wire (SCOPE.md §1).
    public var maxChunkLength = 0
    /// Re-resolve by `source_id` when the stream is lost (SCOPE.md §2, gap #16).
    public var recoverLostStream = true
    /// No data for this long means the stream has silently stalled.
    public var watchdogThreshold: Duration = .seconds(15)

    public init() {}

    /// `maxBuffered` in samples, for the stream this connection carries.
    func maxBufferLength(for info: StreamInfo) -> Int {
        let seconds = maxBuffered.seconds
        let samples = info.nominalSampleRate > 0
            ? info.nominalSampleRate * seconds
            : seconds * 100
        // The rate is peer-supplied and validated only as non-negative, so the
        // product must be clamped before narrowing: `Int(_: Double)` traps outside
        // `Int`'s range (and `Double(Int.max)` itself rounds up past it).
        return max(1, Int(min(samples, 1e18)))
    }
}

/// One open data-phase connection: handshake, test-pattern gate, then a flat sequence of
/// sample records (SCOPE.md §2.2–2.3).
///
/// This is the layer `StreamInlet` is built on. Use it directly only when you already know
/// the endpoint and want no buffering, recovery or time synchronisation.
package actor DataConnection {
    private nonisolated let connection: TCPConnection
    private let codec: SampleCodec
    private var deducer: TimestampDeducer
    private var buffer = Data()
    private var consumed = 0

    package nonisolated let info: StreamInfo
    package nonisolated let byteOrder: WireByteOrder
    package nonisolated let suppressSubnormals: Bool

    private init(
        connection: TCPConnection, info: StreamInfo, byteOrder: WireByteOrder,
        suppressSubnormals: Bool, leftover: Data
    ) {
        self.connection = connection
        self.info = info
        self.byteOrder = byteOrder
        self.suppressSubnormals = suppressSubnormals
        self.codec = SampleCodec(
            format: info.channelFormat, channelCount: info.channelCount,
            byteOrder: byteOrder, suppressSubnormals: suppressSubnormals)
        self.deducer = TimestampDeducer(nominalSampleRate: info.nominalSampleRate)
        self.buffer = leftover
    }

    /// Connects, negotiates, and passes the test-pattern gate. Returns a connection
    /// positioned at the first real sample.
    package static func open(
        to info: StreamInfo,
        host: String,
        port: UInt16,
        configuration: InletConfiguration = .init(),
        timeout: Duration = .seconds(5)
    ) async throws -> DataConnection {
        // A sub-1.10 outlet is identifiable from the discovery XML, so it can be refused
        // before a socket is opened rather than half-decoded (SCOPE.md §4).
        guard info.protocolVersion >= 110 else {
            throw LSLError.unsupportedProtocolVersion(info.protocolVersion)
        }

        let connection = try TCPConnection(host: host, port: port)
        do {
            try await connection.open(timeout: timeout)

            try await connection.send(
                Handshake.request(
                    for: info,
                    maxBufferLength: configuration.maxBufferLength(for: info),
                    maxChunkLength: configuration.maxChunkLength))

            var buffer = Data()
            let headerEnd = try await readUntil(
                Handshake.terminator, on: connection, into: &buffer)
            let negotiated = try Handshake.negotiate(buffer[..<headerEnd], for: info)

            let feed = DataConnection(
                connection: connection, info: info, byteOrder: negotiated.byteOrder,
                suppressSubnormals: negotiated.suppressSubnormals,
                leftover: Data(buffer[headerEnd...]))
            try await feed.validateTestPatterns()
            return feed
        } catch {
            connection.close()
            throw error
        }
    }

    /// Two test-pattern samples, offsets 4 then 2, compared for exact equality including
    /// the timestamp. A mismatch is a hard gate: the formats are incompatible and the
    /// connection is dropped (SCOPE.md §2.2).
    private func validateTestPatterns() async throws {
        for offset in TestPattern.offsets {
            let expected = try TestPattern.sample(
                format: info.channelFormat, channelCount: info.channelCount, offset: offset)
            guard try await nextRecord() == expected else {
                throw LSLError.testPatternMismatch
            }
        }
        compact()
    }

    package func nextSample() async throws -> Sample {
        deducer.materialise(try await nextRecord())
    }

    private func nextRecord() async throws -> SampleRecord {
        while true {
            var reader = ByteReader(buffer, offset: consumed)
            do {
                let record = try codec.decode(from: &reader)
                consumed = reader.offset
                if consumed > 1 << 16 { compact() }
                return record
            } catch LSLError.incompleteRecord {
                guard let more = try await connection.receive(), !more.isEmpty else {
                    throw LSLError.lost("the outlet closed the connection")
                }
                buffer.append(more)
            }
        }
    }

    private func compact() {
        buffer = Data(buffer[(buffer.startIndex + consumed)...])
        consumed = 0
    }

    package nonisolated func close() {
        connection.close()
    }

    /// Reads until `marker` appears, and returns the index just past it.
    private static func readUntil(
        _ marker: Data, on connection: TCPConnection, into buffer: inout Data
    ) async throws -> Data.Index {
        while true {
            if let range = buffer.range(of: marker) {
                return range.upperBound
            }
            guard let more = try await connection.receive(), !more.isEmpty else {
                throw LSLError.lost("the outlet closed before the handshake completed")
            }
            buffer.append(more)
        }
    }
}
