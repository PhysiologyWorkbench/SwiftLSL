import Foundation
import Testing

@testable import LSLCore

@Suite("Handshake")
struct HandshakeTests {
    static func request(format: ChannelFormat = .float32) -> HandshakeRequest {
        HandshakeRequest(
            protocolVersion: 110,
            uid: "9f066061-97af-4113-b79c-1f395da8aeb1",
            format: format,
            maxBufferLength: 360,
            maxChunkLength: 0,
            hostname: "recorder.local",
            sourceID: "src-1",
            sessionID: "default"
        )
    }

    @Test("The request has the field order and CRLF framing of SCOPE §2.2")
    func requestFraming() {
        let encoded = String(decoding: Self.request().encoded(), as: UTF8.self)
        #expect(
            encoded == """
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

    @Test("Value-Size and Supports-Subnormals follow the channel format")
    func formatDependentHeaders() {
        func header(_ format: ChannelFormat, _ name: String) -> String? {
            String(decoding: Self.request(format: format).encoded(), as: UTF8.self)
                .components(separatedBy: "\r\n")
                .first { $0.hasPrefix(name) }
        }
        // A wrong Value-Size makes the outlet downgrade to protocol 1.00
        // (`src/tcp_server.cpp:641-643`).
        #expect(header(.double64, "Value-Size") == "Value-Size: 8")
        #expect(header(.int16, "Value-Size") == "Value-Size: 2")
        #expect(header(.string, "Value-Size") == "Value-Size: 0")
        #expect(header(.double64, "Supports-Subnormals") == "Supports-Subnormals: 1")
        #expect(header(.int32, "Supports-Subnormals") == "Supports-Subnormals: 0")
        #expect(header(.string, "Supports-Subnormals") == "Supports-Subnormals: 0")
    }

    @Test("The proposed version is the lower of ours and the stream's")
    func proposedVersion() {
        #expect(HandshakeRequest.proposedVersion(streamVersion: 110) == 110)
        #expect(HandshakeRequest.proposedVersion(streamVersion: 100) == 100)
        #expect(HandshakeRequest.proposedVersion(streamVersion: 200) == 110)
    }

    // MARK: - Response parsing

    @Test("A live liblsl response parses and validates", arguments: TestPatternFixtures.all)
    func capturedResponse(fixtures: TestPatternFixtures) throws {
        let block = Data(fixtures.responseHeader.utf8)
        let response = try HandshakeResponse.parse(block)
        #expect(response.version == 110)
        #expect(response.statusCode == 200)
        #expect(response.statusMessage == "OK")
        #expect(response.byteOrderValue == 1234)
        #expect(response.suppressSubnormals == false)
        #expect(response.dataProtocolVersion == 110)
        let uid = try #require(response.uid)
        #expect(try response.validate(expectedUID: uid, format: .float32) == .little)
    }

    @Test("Header keys are matched case-insensitively")
    func lowerCasedKeys() throws {
        let response = try HandshakeResponse.parse(
            Data("LSL/110 200 OK\r\nBYTE-ORDER: 4321\r\nSUPPRESS-SUBNORMALS: 1\r\nData-Protocol-VERSION: 110\r\n\r\n".utf8))
        #expect(response.byteOrderValue == 4321)
        #expect(response.suppressSubnormals)
        #expect(response.dataProtocolVersion == 110)
    }

    @Test("Everything after a semicolon is a comment")
    func commentsStripped() throws {
        let response = try HandshakeResponse.parse(
            Data("LSL/110 200 OK\r\nByte-Order: 4321 ; big endian peer\r\nData-Protocol-Version: 110\r\n\r\n".utf8))
        #expect(response.byteOrderValue == 4321)
    }

    @Test("Byte-Order 0 means portable and remaps to native")
    func portableByteOrderRemap() throws {
        let response = try HandshakeResponse.parse(
            Data("LSL/110 200 OK\r\nByte-Order: 0\r\nData-Protocol-Version: 110\r\n\r\n".utf8))
        #expect(response.byteOrderValue == WireByteOrder.native.rawValue)
        #expect(try response.validate(expectedUID: "", format: .float32) == .native)
    }

    @Test("Absent headers take liblsl's defaults, which refuses the connection")
    func absentHeaders() throws {
        // data_protocol_version defaults to 100 (`src/data_receiver.cpp:160-161`), and
        // protocol 1.00 is out of scope (SCOPE.md §4).
        let response = try HandshakeResponse.parse(Data("LSL/110 200 OK\r\n\r\n".utf8))
        #expect(response.dataProtocolVersion == 100)
        #expect(response.byteOrderValue == WireByteOrder.native.rawValue)
        #expect(throws: LSLError.unsupportedProtocolVersion(100)) {
            _ = try response.validate(expectedUID: "", format: .float32)
        }
    }

    @Test("A mid-handshake downgrade to 1.00 is refused with its own error")
    func downgradeRefused() throws {
        let response = try HandshakeResponse.parse(
            Data("LSL/110 200 OK\r\nData-Protocol-Version: 100\r\n\r\n".utf8))
        #expect(throws: LSLError.unsupportedProtocolVersion(100)) {
            _ = try response.validate(expectedUID: "", format: .float32)
        }
    }

    @Test("Status 404 is a lost stream, not a generic error")
    func status404() throws {
        let response = try HandshakeResponse.parse(Data("LSL/110 404 Not found\r\n\r\n".utf8))
        #expect(response.statusMessage == "Not found")
        #expect(throws: LSLError.lost("the address does not serve this stream (stale resolve)")) {
            _ = try response.validate(expectedUID: "", format: .float32)
        }
    }

    @Test("Status 505 is an error carrying its message")
    func status505() throws {
        let response = try HandshakeResponse.parse(
            Data("LSL/110 505 Version not supported\r\n\r\n".utf8))
        #expect(
            throws: LSLError.statusError(code: 505, message: "Version not supported")
        ) {
            _ = try response.validate(expectedUID: "", format: .float32)
        }
    }

    @Test("A 3xx redirect counts as a lost stream")
    func redirect() throws {
        let response = try HandshakeResponse.parse(Data("LSL/110 302 Found\r\n\r\n".utf8))
        #expect(throws: LSLError.lost("the outlet requested a redirect")) {
            _ = try response.validate(expectedUID: "", format: .float32)
        }
    }

    @Test("A too-new major version is refused")
    func futureVersion() throws {
        let response = try HandshakeResponse.parse(
            Data("LSL/200 200 OK\r\nData-Protocol-Version: 110\r\n\r\n".utf8))
        #expect(throws: LSLError.unsupportedProtocolVersion(200)) {
            _ = try response.validate(expectedUID: "", format: .float32)
        }
    }

    @Test("A newer minor version of the same major is accepted")
    func newerMinorVersion() throws {
        // Comparison is by major only (`src/data_receiver.cpp:199-203`).
        let response = try HandshakeResponse.parse(
            Data("LSL/199 200 OK\r\nData-Protocol-Version: 110\r\n\r\n".utf8))
        #expect(try response.validate(expectedUID: "", format: .float32) == .native)
    }

    @Test("A mismatched UID is rejected")
    func uidMismatch() throws {
        let response = try HandshakeResponse.parse(
            Data("LSL/110 200 OK\r\nUID: aaaa\r\nData-Protocol-Version: 110\r\n\r\n".utf8))
        #expect(throws: LSLError.uidMismatch(expected: "bbbb", received: "aaaa")) {
            _ = try response.validate(expectedUID: "bbbb", format: .float32)
        }
        #expect(try response.validate(expectedUID: "AAAA", format: .float32) == .native)
    }

    @Test("A byte order this format cannot use is rejected")
    func unsupportedByteOrder() throws {
        let response = try HandshakeResponse.parse(
            Data("LSL/110 200 OK\r\nByte-Order: 2134\r\nData-Protocol-Version: 110\r\n\r\n".utf8))
        #expect(throws: LSLError.unsupportedByteOrder(2134)) {
            _ = try response.validate(expectedUID: "", format: .float32)
        }
        // int8 is the one format whose in-memory width is a single byte, so any value goes.
        #expect(try response.validate(expectedUID: "", format: .int8) == .native)
        // String length prefixes are byte-swapped, so string streams do need a real order.
        #expect(throws: LSLError.unsupportedByteOrder(2134)) {
            _ = try response.validate(expectedUID: "", format: .string)
        }
    }

    @Test("A malformed status line is rejected", arguments: [
        "", "200 OK\r\n\r\n", "HTTP/1.1 200 OK\r\n\r\n", "LSL/110 200\r\n\r\n",
        "LSL/abc 200 OK\r\n\r\n",
    ])
    func malformedStatusLine(text: String) {
        #expect(throws: (any Error).self) {
            _ = try HandshakeResponse.parse(Data(text.utf8))
        }
    }

    @Test("A line without a colon is ignored, as liblsl ignores it")
    func headerWithoutColon() throws {
        let response = try HandshakeResponse.parse(
            Data("LSL/110 200 OK\r\ngarbage line\r\nData-Protocol-Version: 110\r\n\r\n".utf8))
        #expect(response.dataProtocolVersion == 110)
    }
}
