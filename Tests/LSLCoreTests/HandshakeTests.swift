import Foundation
import Testing

@testable import LSLCore

@Suite("Handshake")
struct HandshakeTests {
    static func stream(
        _ format: ChannelFormat = .float32, uid: String = "", protocolVersion: Int = 110
    ) -> StreamInfo {
        StreamInfo(
            name: "Demo", channelCount: 8, channelFormat: format, sourceID: "src-1",
            uid: uid, hostname: "recorder.local", protocolVersion: protocolVersion)
    }

    static func negotiate(_ header: String, _ stream: StreamInfo = stream()) throws
        -> Handshake.Negotiation
    {
        try Handshake.negotiate(Data(header.utf8), for: stream)
    }

    @Test("The request has the field order and CRLF framing of SCOPE §2.2")
    func requestFraming() {
        let request = Handshake.request(
            for: Self.stream(uid: "9f066061-97af-4113-b79c-1f395da8aeb1"),
            maxBufferLength: 360, maxChunkLength: 0)
        #expect(
            String(decoding: request, as: UTF8.self) == """
                LSL:streamfeed/110 9f066061-97af-4113-b79c-1f395da8aeb1\r
                Native-Byte-Order: 1234\r
                Endian-Performance: 0\r
                Has-IEEE754-Floats: 1\r
                Supports-Subnormals: 1\r
                Value-Size: 4\r
                Data-Protocol-Version: 110\r
                Max-Buffer-Length: 360\r
                Max-Chunk-Length: 0\r
                Hostname: recorder.local\r
                Source-Id: src-1\r
                Session-Id: default\r
                \r

                """)
    }

    static func header(_ stream: StreamInfo, _ name: String) -> String? {
        String(
            decoding: Handshake.request(for: stream, maxBufferLength: 360, maxChunkLength: 0),
            as: UTF8.self
        )
        .components(separatedBy: "\r\n")
        .first { $0.hasPrefix(name) }
    }

    @Test("Value-Size and Supports-Subnormals follow the channel format")
    func formatDependentHeaders() {
        // A wrong Value-Size makes the outlet downgrade to protocol 1.00
        // (`src/tcp_server.cpp:641-643`).
        #expect(Self.header(Self.stream(.double64), "Value-Size") == "Value-Size: 8")
        #expect(Self.header(Self.stream(.int16), "Value-Size") == "Value-Size: 2")
        #expect(Self.header(Self.stream(.string), "Value-Size") == "Value-Size: 0")
        #expect(
            Self.header(Self.stream(.double64), "Supports-Subnormals") == "Supports-Subnormals: 1")
        #expect(Self.header(Self.stream(.int32), "Supports-Subnormals") == "Supports-Subnormals: 0")
        #expect(Self.header(Self.stream(.string), "Supports-Subnormals") == "Supports-Subnormals: 0")
    }

    @Test("The proposed version is the lower of ours and the stream's")
    func proposedVersion() {
        // A sub-1.10 stream never reaches the encoder: it is refused from the discovery XML
        // (SCOPE.md §4), so only "same" and "newer than ours" are reachable.
        let newer = Self.stream(protocolVersion: 199)
        #expect(Self.header(newer, "LSL:streamfeed") == "LSL:streamfeed/110 ")
        #expect(Self.header(newer, "Data-Protocol-Version") == "Data-Protocol-Version: 110")
    }

    // MARK: - Response parsing

    @Test("A live liblsl response parses and validates", arguments: TestPatternFixtures.all)
    func capturedResponse(fixtures: TestPatternFixtures) throws {
        // The two captures differ in whether the committed block carries the trailing
        // terminator, which is itself the coverage that either framing parses.
        let header = fixtures.responseHeader
        #expect(
            try Self.negotiate(header, Self.stream(uid: fixtures.responseUID))
                == Handshake.Negotiation(byteOrder: .little, suppressSubnormals: false))
        // Pins the parsed UID against the header as read independently of the parser.
        #expect(throws: LSLError.uidMismatch(expected: "other", received: fixtures.responseUID)) {
            _ = try Self.negotiate(header, Self.stream(uid: "other"))
        }
    }

    @Test("Header keys are matched case-insensitively")
    func lowerCasedKeys() throws {
        let negotiated = try Self.negotiate(
            "LSL/110 200 OK\r\nBYTE-ORDER: 4321\r\nSUPPRESS-SUBNORMALS: 1\r\nData-Protocol-VERSION: 110\r\n\r\n")
        #expect(negotiated == Handshake.Negotiation(byteOrder: .big, suppressSubnormals: true))
    }

    @Test("Everything after a semicolon is a comment")
    func commentsStripped() throws {
        let negotiated = try Self.negotiate(
            "LSL/110 200 OK\r\nByte-Order: 4321 ; big endian peer\r\nData-Protocol-Version: 110\r\n\r\n")
        #expect(negotiated.byteOrder == .big)
    }

    @Test("Byte-Order 0 means portable and remaps to native")
    func portableByteOrderRemap() throws {
        let negotiated = try Self.negotiate(
            "LSL/110 200 OK\r\nByte-Order: 0\r\nData-Protocol-Version: 110\r\n\r\n")
        #expect(negotiated.byteOrder == .native)
    }

    @Test("Absent headers take liblsl's defaults, which refuses the connection")
    func absentHeaders() {
        // data_protocol_version defaults to 100 (`src/data_receiver.cpp:160-161`), and
        // protocol 1.00 is out of scope (SCOPE.md §4).
        #expect(throws: LSLError.unsupportedProtocolVersion(100)) {
            _ = try Self.negotiate("LSL/110 200 OK\r\n\r\n")
        }
    }

    @Test("A mid-handshake downgrade to 1.00 is refused with its own error")
    func downgradeRefused() {
        #expect(throws: LSLError.unsupportedProtocolVersion(100)) {
            _ = try Self.negotiate("LSL/110 200 OK\r\nData-Protocol-Version: 100\r\n\r\n")
        }
    }

    @Test("Status 404 is a lost stream, not a generic error")
    func status404() {
        #expect(throws: LSLError.lost("the address does not serve this stream (stale resolve)")) {
            _ = try Self.negotiate("LSL/110 404 Not found\r\n\r\n")
        }
    }

    @Test("Status 505 is an error carrying its message")
    func status505() {
        #expect(throws: LSLError.statusError(code: 505, message: "Version not supported")) {
            _ = try Self.negotiate("LSL/110 505 Version not supported\r\n\r\n")
        }
    }

    @Test("A 3xx redirect counts as a lost stream")
    func redirect() {
        #expect(throws: LSLError.lost("the outlet requested a redirect")) {
            _ = try Self.negotiate("LSL/110 302 Found\r\n\r\n")
        }
    }

    @Test("A too-new major version is refused")
    func futureVersion() {
        #expect(throws: LSLError.unsupportedProtocolVersion(200)) {
            _ = try Self.negotiate("LSL/200 200 OK\r\nData-Protocol-Version: 110\r\n\r\n")
        }
    }

    @Test("A newer minor version of the same major is accepted")
    func newerMinorVersion() throws {
        // Comparison is by major only (`src/data_receiver.cpp:199-203`).
        let negotiated = try Self.negotiate(
            "LSL/199 200 OK\r\nData-Protocol-Version: 110\r\n\r\n")
        #expect(negotiated.byteOrder == .native)
    }

    @Test("A mismatched UID is rejected")
    func uidMismatch() throws {
        let header = "LSL/110 200 OK\r\nUID: aaaa\r\nData-Protocol-Version: 110\r\n\r\n"
        #expect(throws: LSLError.uidMismatch(expected: "bbbb", received: "aaaa")) {
            _ = try Self.negotiate(header, Self.stream(uid: "bbbb"))
        }
        #expect(try Self.negotiate(header, Self.stream(uid: "AAAA")).byteOrder == .native)
    }

    @Test("A byte order this format cannot use is rejected")
    func unsupportedByteOrder() throws {
        let header = "LSL/110 200 OK\r\nByte-Order: 2134\r\nData-Protocol-Version: 110\r\n\r\n"
        #expect(throws: LSLError.unsupportedByteOrder(2134)) {
            _ = try Self.negotiate(header)
        }
        // int8 is the one format whose in-memory width is a single byte, so any value goes.
        #expect(try Self.negotiate(header, Self.stream(.int8)).byteOrder == .native)
        // String length prefixes are byte-swapped, so string streams do need a real order.
        #expect(throws: LSLError.unsupportedByteOrder(2134)) {
            _ = try Self.negotiate(header, Self.stream(.string))
        }
    }

    @Test("A malformed status line is rejected", arguments: [
        "", "200 OK\r\n\r\n", "HTTP/1.1 200 OK\r\n\r\n", "LSL/110 200\r\n\r\n",
        "LSL/abc 200 OK\r\n\r\n",
    ])
    func malformedStatusLine(text: String) {
        #expect(throws: (any Error).self) {
            _ = try Self.negotiate(text)
        }
    }

    @Test("A line without a colon is ignored, as liblsl ignores it")
    func headerWithoutColon() throws {
        let negotiated = try Self.negotiate(
            "LSL/110 200 OK\r\ngarbage line\r\nData-Protocol-Version: 110\r\n\r\n")
        #expect(negotiated.byteOrder == .native)
    }
}
