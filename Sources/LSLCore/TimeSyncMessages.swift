import Foundation

/// The `LSL:timedata` exchange (SCOPE.md §2.5, `src/time_receiver.cpp:131-152`,
/// `src/udp_server.cpp:152-168`). Framing and arithmetic only — no sockets.
package enum TimeSyncMessage {
    /// ```
    /// LSL:timedata\r\n
    /// <wave id> <t0>\r\n
    /// ```
    /// with 16 significant digits, as `liblsl` writes it.
    package static func probe(waveID: Int32, t0: Double) -> Data {
        Data("LSL:timedata\r\n\(waveID) \(format(t0))\r\n".utf8)
    }

    /// The outlet's reply: a **leading space**, four whitespace-separated fields, and no
    /// trailing newline. Both quirks are only discoverable from the source (gap #6).
    package static func reply(waveID: Int32, t0: Double, t1: Double, t2: Double) -> Data {
        Data(" \(waveID) \(format(t0)) \(format(t1)) \(format(t2))".utf8)
    }

    package struct Reply: Sendable, Hashable {
        package let waveID: Int32
        /// Our send time, echoed back.
        package let t0: Double
        /// The outlet's receive time.
        package let t1: Double
        /// The outlet's send time.
        package let t2: Double
    }

    package static func parseReply(_ datagram: Data) throws -> Reply {
        let fields = String(decoding: datagram, as: UTF8.self)
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" })
        guard fields.count >= 4, let waveID = Int32(fields[0]),
            let t0 = Double(fields[1]), let t1 = Double(fields[2]), let t2 = Double(fields[3])
        else {
            throw LSLError.malformedMessage("malformed timedata reply")
        }
        return Reply(waveID: waveID, t0: t0, t1: t1, t2: t2)
    }

    /// One probe's round-trip time and clock offset, given the local receive time `t3`
    /// (SCOPE.md §2.5).
    package static func measure(_ reply: Reply, t3: Double) -> (rtt: Double, offset: Double) {
        let rtt = (t3 - reply.t0) - (reply.t2 - reply.t1)
        let offset = ((reply.t1 - reply.t0) + (reply.t2 - t3)) / 2
        return (rtt, offset)
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.16g", value)
    }
}
