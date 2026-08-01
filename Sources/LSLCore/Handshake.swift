import Foundation

/// The `LSL:streamfeed` request an inlet opens the data phase with
/// (SCOPE.md §2.2, `src/data_receiver.cpp:168-190`).
package struct HandshakeRequest: Sendable {
    package var protocolVersion: Int
    package var uid: String
    package var format: ChannelFormat
    package var maxBufferLength: Int
    package var maxChunkLength: Int
    package var hostname: String
    package var sourceID: String
    package var sessionID: String

    /// Advertised byte-swapping throughput. The outlet converts on our behalf only when
    /// it beats this figure (`src/tcp_server.cpp:655-663`), so the default of 0 says
    /// "you convert if you can" — the decoder handles either outcome. `liblsl` sends a
    /// measured value here; benchmarking at connect time buys nothing an inlet needs.
    package var endianPerformance: Double = 0

    package init(
        protocolVersion: Int,
        uid: String,
        format: ChannelFormat,
        maxBufferLength: Int,
        maxChunkLength: Int,
        hostname: String,
        sourceID: String,
        sessionID: String
    ) {
        self.protocolVersion = protocolVersion
        self.uid = uid
        self.format = format
        self.maxBufferLength = maxBufferLength
        self.maxChunkLength = maxChunkLength
        self.hostname = hostname
        self.sourceID = sourceID
        self.sessionID = sessionID
    }

    /// `min(our maximum, the stream's advertised version)` (`src/data_receiver.cpp:165-167`).
    package static func proposedVersion(streamVersion: Int) -> Int {
        min(LSLCore.maximumProtocolVersion, streamVersion)
    }

    package func encoded() -> Data {
        var lines = ["LSL:streamfeed/\(protocolVersion) \(uid)"]
        lines.append("Native-Byte-Order: \(WireByteOrder.native.rawValue)")
        lines.append("Endian-Performance: \(Int(endianPerformance))")
        lines.append("Has-IEEE754-Floats: 1")
        lines.append("Supports-Subnormals: \(format.hasSubnormals ? 1 : 0)")
        lines.append("Value-Size: \(format.valueSize)")
        lines.append("Data-Protocol-Version: \(protocolVersion)")
        lines.append("Max-Buffer-Length: \(maxBufferLength)")
        lines.append("Max-Chunk-Length: \(maxChunkLength)")
        lines.append("Hostname: \(hostname)")
        lines.append("Source-Id: \(sourceID)")
        lines.append("Session-Id: \(sessionID)")
        return Data((lines.map { $0 + "\r\n" }.joined() + "\r\n").utf8)
    }
}

/// The outlet's answer to a `LSL:streamfeed` request
/// (SCOPE.md §2.2, `src/tcp_server.cpp:671-678`).
package struct HandshakeResponse: Sendable, Hashable {
    /// From the `LSL/<version>` status line.
    package let version: Int
    package let statusCode: Int
    package let statusMessage: String
    package let uid: String?
    /// After the `0 → native` remap; not yet checked against the channel format.
    package let byteOrderValue: Int
    package let suppressSubnormals: Bool
    /// Defaults to 100 when the header is absent, exactly as `liblsl` does — an outlet
    /// that omits it is asking for the 1.00 archive format, which this package refuses
    /// (`src/data_receiver.cpp:160-161`, SCOPE.md §4).
    package let dataProtocolVersion: Int

    /// The header block ends here; everything after is test-pattern bytes.
    package static let terminator = Data("\r\n\r\n".utf8)

    /// Parses a complete header block, terminator included.
    package static func parse(_ block: Data) throws -> HandshakeResponse {
        let text = String(decoding: block, as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else {
            throw LSLError.malformedMessage("empty handshake response")
        }
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
                // lower-casing above; keep the parsed form for the caller to check.
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

        return HandshakeResponse(
            version: version,
            statusCode: statusCode,
            statusMessage: parts.dropFirst(2).joined(separator: " "),
            uid: uid,
            byteOrderValue: byteOrderValue,
            suppressSubnormals: suppressSubnormals,
            dataProtocolVersion: dataProtocolVersion
        )
    }

    /// Applies every acceptance rule the reference inlet applies, in its order, and
    /// returns the byte order the sample codec must use.
    package func validate(expectedUID: String, format: ChannelFormat) throws -> WireByteOrder {
        guard version / 100 <= LSLCore.maximumProtocolVersion / 100 else {
            throw LSLError.unsupportedProtocolVersion(version)
        }
        if statusCode == 404 {
            throw LSLError.lost("the address does not serve this stream (stale resolve)")
        }
        if statusCode >= 400 {
            throw LSLError.statusError(code: statusCode, message: statusMessage)
        }
        if statusCode >= 300 {
            throw LSLError.lost("the outlet requested a redirect")
        }
        if let uid, uid.caseInsensitiveCompare(expectedUID) != .orderedSame {
            throw LSLError.uidMismatch(expected: expectedUID, received: uid)
        }
        guard dataProtocolVersion <= LSLCore.maximumProtocolVersion,
            dataProtocolVersion >= 110
        else {
            throw LSLError.unsupportedProtocolVersion(dataProtocolVersion)
        }
        guard format.canConvertByteOrder(byteOrderValue) else {
            throw LSLError.unsupportedByteOrder(byteOrderValue)
        }
        return WireByteOrder(rawValue: byteOrderValue) ?? .native
    }
}
