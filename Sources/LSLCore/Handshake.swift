import Foundation

/// The data-phase handshake: the `LSL:streamfeed` request and the outlet's answer
/// (SCOPE.md §2.2).
package enum Handshake {
    /// The header block ends here; everything after is test-pattern bytes.
    package static let terminator = Data("\r\n\r\n".utf8)

    /// The request an inlet opens the data phase with (`src/data_receiver.cpp:168-190`).
    ///
    /// `Endian-Performance` is a policy knob, not a fact: the outlet converts on our behalf
    /// only when its own measurement beats the figure we declare
    /// (`src/tcp_server.cpp:655-663`), so 0 says "you convert if you can" — the decoder
    /// handles either outcome. `liblsl` benchmarks at connect time; that buys an inlet
    /// nothing.
    package static func request(
        for stream: StreamInfo, maxBufferLength: Int, maxChunkLength: Int
    ) -> Data {
        // `min(our maximum, the stream's advertised version)` (`src/data_receiver.cpp:165-167`).
        let version = min(LSLCore.maximumProtocolVersion, stream.protocolVersion)
        let format = stream.channelFormat
        let lines = [
            "LSL:streamfeed/\(version) \(stream.uid)",
            "Native-Byte-Order: \(WireByteOrder.native.rawValue)",
            "Endian-Performance: 0",
            "Has-IEEE754-Floats: 1",
            "Supports-Subnormals: \(format.hasSubnormals ? 1 : 0)",
            "Value-Size: \(format.valueSize)",
            "Data-Protocol-Version: \(version)",
            "Max-Buffer-Length: \(maxBufferLength)",
            "Max-Chunk-Length: \(maxChunkLength)",
            "Hostname: \(stream.hostname)",
            "Source-Id: \(stream.sourceID)",
            "Session-Id: \(stream.sessionID)",
        ]
        return Data((lines.map { $0 + "\r\n" }.joined() + "\r\n").utf8)
    }

    /// What the handshake settles, and all the data phase needs from it.
    package struct Negotiation: Sendable, Hashable {
        package let byteOrder: WireByteOrder
        package let suppressSubnormals: Bool
    }

    /// Parses the outlet's answer (`src/tcp_server.cpp:671-678`) and applies every
    /// acceptance rule the reference inlet applies, in its order
    /// (`src/data_receiver.cpp:193-255`). Takes a complete header block, terminator
    /// included.
    package static func negotiate(_ block: Data, for stream: StreamInfo) throws -> Negotiation {
        let text = String(decoding: block, as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst()

        // splitandtrim(buf, ' ', false): split on spaces, empties dropped.
        let parts = statusLine.split(separator: " ").map(String.init)
        guard parts.count >= 3, parts[0].hasPrefix("LSL/"), let version = Int(parts[0].dropFirst(4)),
            let statusCode = Int(parts[1])
        else {
            throw LSLError.malformedMessage("malformed status line: \(statusLine)")
        }

        var uid: String?
        var byteOrderValue = WireByteOrder.native.rawValue
        var suppressSubnormals = false
        // Defaults to 100 when the header is absent, exactly as `liblsl` does — an outlet
        // that omits it is asking for the 1.00 archive format, which this package refuses
        // (`src/data_receiver.cpp:160-161`, SCOPE.md §4).
        var dataProtocolVersion = 100

        for line in lines {
            if line.isEmpty { break }
            // Anything after a `;` is a comment, and keys *and values* are lower-cased
            // before matching (`src/data_receiver.cpp:219-226`).
            var body = line
            if let semicolon = body.firstIndex(of: ";") {
                body = String(body[body.startIndex..<semicolon])
            }
            body = body.lowercased()
            guard let colon = body.firstIndex(of: ":") else { continue }
            let key = body[body.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            let value = body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces)

            switch key {
            case "uid":
                // The UID is compared case-insensitively as a consequence of the
                // lower-casing above.
                uid = value
            case "byte-order":
                guard let raw = Int(value) else {
                    throw LSLError.malformedMessage("non-numeric Byte-Order: \(value)")
                }
                // 0 means "portable" and is remapped to native, for interoperability with
                // liblsl ≈1.13 (`src/data_receiver.cpp:231`).
                byteOrderValue = raw == WireByteOrder.portable ? WireByteOrder.native.rawValue : raw
            case "suppress-subnormals":
                suppressSubnormals = value == "1"
            case "data-protocol-version":
                guard let raw = Int(value) else {
                    throw LSLError.malformedMessage("non-numeric Data-Protocol-Version: \(value)")
                }
                dataProtocolVersion = raw
            default:
                break
            }
        }

        guard version / 100 <= LSLCore.maximumProtocolVersion / 100 else {
            throw LSLError.unsupportedProtocolVersion(version)
        }
        if statusCode == 404 {
            throw LSLError.lost("the address does not serve this stream (stale resolve)")
        }
        if statusCode >= 400 {
            throw LSLError.statusError(
                code: statusCode, message: parts.dropFirst(2).joined(separator: " "))
        }
        if statusCode >= 300 {
            throw LSLError.lost("the outlet requested a redirect")
        }
        if let uid, uid.caseInsensitiveCompare(stream.uid) != .orderedSame {
            throw LSLError.uidMismatch(expected: stream.uid, received: uid)
        }
        guard dataProtocolVersion <= LSLCore.maximumProtocolVersion,
            dataProtocolVersion >= 110
        else {
            throw LSLError.unsupportedProtocolVersion(dataProtocolVersion)
        }
        guard stream.channelFormat.canConvertByteOrder(byteOrderValue) else {
            throw LSLError.unsupportedByteOrder(byteOrderValue)
        }
        // A byte order no format can name is only reachable for single-byte values, where
        // it makes no difference.
        return Negotiation(
            byteOrder: WireByteOrder(rawValue: byteOrderValue) ?? .native,
            suppressSubnormals: suppressSubnormals)
    }
}
