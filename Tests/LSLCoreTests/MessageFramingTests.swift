import Foundation
import Testing

@testable import LSLCore

@Suite("Discovery, time-sync and query framing")
struct MessageFramingTests {
    @Test("A discovery query is three CRLF-terminated lines")
    func discoveryQueryFraming() {
        let datagram = DiscoveryMessage.query(
            "session_id='default' and type='EEG'", returnPort: 16572, queryID: "1234567890")
        #expect(
            String(decoding: datagram, as: UTF8.self) == """
                LSL:shortinfo\r
                session_id='default' and type='EEG'\r
                16572 1234567890\r

                """)
    }

    @Test("Query ids are opaque and unique")
    func queryIDs() {
        let ids = (0..<64).map { _ in DiscoveryMessage.newQueryID() }
        #expect(Set(ids).count == ids.count)
    }

    @Test("A reply splits into the echoed id and the XML after it")
    func replyParsing() throws {
        let xml = "<?xml version=\"1.0\"?>\n<info>\n\t<name>X</name>\n</info>\n"
        let (id, body) = try DiscoveryMessage.parseReply(
            DiscoveryMessage.reply(queryID: "42", xml: xml))
        #expect(id == "42")
        #expect(String(decoding: body, as: UTF8.self) == xml)
        #expect(try StreamInfoXML.parseTree(body).name == "info")
    }

    @Test("A reply with no id line is rejected")
    func replyWithoutIDLine() {
        #expect(throws: (any Error).self) {
            _ = try DiscoveryMessage.parseReply(Data("no newline here".utf8))
        }
    }

    // MARK: - Queries

    @Test("Resolves are scoped to a session")
    func sessionScoping() {
        #expect(Query.session("default") == "session_id='default'")
        #expect(
            Query.session("default", and: Query.property("type", equals: "EEG"))
                == "session_id='default' and type='EEG'")
    }

    @Test("A recovery query omits nominal_srate")
    func recoveryQuery() {
        // Float round-tripping breaks matching, so liblsl leaves the rate out
        // (SCOPE.md gap #16).
        let info = StreamInfo(
            name: "Demo", type: "EEG", channelCount: 3, nominalSampleRate: 512,
            channelFormat: .float32, sourceID: "sid-1", uid: "u")
        #expect(
            Query.recovery(for: info)
                == "channel_count='3' and name='Demo' and type='EEG' and source_id='sid-1' "
                + "and channel_format='float32'")
        #expect(!Query.recovery(for: info).contains("nominal_srate"))
    }

    @Test("A recovery query drops absent fields")
    func recoveryQueryWithoutOptionalFields() {
        let info = StreamInfo(name: "Demo", channelCount: 1, channelFormat: .string, uid: "u")
        #expect(
            Query.recovery(for: info)
                == "channel_count='1' and name='Demo' and channel_format='string'")
    }

    @Test("A quote in a value cannot break the predicate")
    func quotesRemoved() {
        // XPath 1.0 string literals have no escape syntax, so the quote is dropped rather
        // than emitted into a predicate the outlet would reject.
        #expect(Query.property("name", equals: "Bob's rig") == "name='Bobs rig'")
    }

    // MARK: - Time sync

    @Test("A probe is two lines with 16 significant digits")
    func probeFraming() {
        #expect(
            String(decoding: TimeSyncMessage.probe(waveID: 12345, t0: 4161370.646552416),
                as: UTF8.self) == "LSL:timedata\r\n12345 4161370.646552416\r\n")
    }

    @Test("A reply has a leading space and no trailing newline")
    func replyFraming() {
        // Both quirks are only discoverable from the source (SCOPE.md gap #6).
        let reply = TimeSyncMessage.reply(waveID: 7, t0: 1, t1: 2, t2: 3)
        #expect(String(decoding: reply, as: UTF8.self) == " 7 1 2 3")
    }

    @Test("A reply parses back to its four fields")
    func replyRoundTrip() throws {
        let parsed = try TimeSyncMessage.parseReply(
            TimeSyncMessage.reply(
                waveID: 987654, t0: 1000.5, t1: 2000.25, t2: 2000.75))
        #expect(parsed == TimeSyncMessage.Reply(
            waveID: 987654, t0: 1000.5, t1: 2000.25, t2: 2000.75))
    }

    @Test("A truncated reply is rejected")
    func malformedReply() {
        for text in ["", " 1 2 3", "not numbers at all"] {
            #expect(throws: (any Error).self) {
                _ = try TimeSyncMessage.parseReply(Data(text.utf8))
            }
        }
    }

    @Test("RTT and offset follow the documented formulas")
    func offsetArithmetic() {
        // A remote clock exactly 10 s ahead, symmetric 200 ms round trip:
        // t0 = 100, t1 = 110.1, t2 = 110.1, t3 = 100.2.
        let reply = TimeSyncMessage.Reply(waveID: 1, t0: 100, t1: 110.1, t2: 110.1)
        let (rtt, offset) = TimeSyncMessage.measure(reply, t3: 100.2)
        #expect(abs(rtt - 0.2) < 1e-12)
        #expect(abs(offset - 10.0) < 1e-12)
        // The published correction is the negation: adding it maps a remote timestamp into
        // the local clock (SCOPE.md gap #8 — getting this backwards is doubly wrong).
        #expect(abs(-offset + 110.1 - 100.1) < 1e-12)
    }

    @Test("An asymmetric path biases the offset by half the asymmetry")
    func asymmetricPath() {
        // Outbound 300 ms, inbound 100 ms, remote clock 0: t0 = 0, t1 = 0.3, t2 = 0.3,
        // t3 = 0.4. RTT is 0.4; the offset picks up half the 200 ms asymmetry.
        let (rtt, offset) = TimeSyncMessage.measure(
            TimeSyncMessage.Reply(waveID: 1, t0: 0, t1: 0.3, t2: 0.3), t3: 0.4)
        #expect(abs(rtt - 0.4) < 1e-12)
        #expect(abs(offset - 0.1) < 1e-12)
    }
}
