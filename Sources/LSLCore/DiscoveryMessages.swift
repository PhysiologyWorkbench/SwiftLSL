import Foundation

/// The `LSL:shortinfo` exchange (SCOPE.md §2.1, `src/resolve_attempt_udp.cpp:53-58`,
/// `src/udp_server.cpp:122-150`). Framing only — the sockets live in `LSL`.
package enum DiscoveryMessage {
    /// ```
    /// LSL:shortinfo\r\n
    /// <query>\r\n
    /// <return port> <query id>\r\n
    /// ```
    package static func query(_ query: String, returnPort: UInt16, queryID: String) -> Data {
        Data("LSL:shortinfo\r\n\(query)\r\n\(returnPort) \(queryID)\r\n".utf8)
    }

    /// A fresh opaque echo token. `liblsl` uses `std::hash` of the query string, but the
    /// responder only echoes it and the querier only compares it against its own value,
    /// so any unique string works — and reproducing libstdc++'s hash would be pointless
    /// (SCOPE.md gap #5).
    package static func newQueryID() -> String {
        String(UInt64.random(in: 0...UInt64.max))
    }

    /// Splits a reply into its echoed query id and the shortinfo XML that follows.
    ///
    /// The id runs to the first `\n` with trailing whitespace trimmed
    /// (`src/resolve_attempt_udp.cpp:110-118`). The reference hands the newline itself to
    /// its parser, which tolerates it; `XMLParser` rejects any byte before the XML
    /// declaration, so leading whitespace is skipped here.
    package static func parseReply(_ datagram: Data) throws -> (queryID: String, xml: Data) {
        guard let newline = datagram.firstIndex(of: 0x0A) else {
            throw LSLError.malformedMessage("discovery reply has no query id line")
        }
        let id = String(decoding: datagram[datagram.startIndex..<newline], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var start = datagram.index(after: newline)
        while start < datagram.endIndex, Self.whitespace.contains(datagram[start]) {
            start = datagram.index(after: start)
        }
        return (id, datagram[start...])
    }

    private static let whitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]

    /// The reply an outlet sends: the echoed id, then the `<desc>`-less info XML.
    package static func reply(queryID: String, xml: String) -> Data {
        Data("\(queryID)\r\n\(xml)".utf8)
    }
}
