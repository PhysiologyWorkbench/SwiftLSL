import Foundation
import Testing

@testable import LSLCore

@Suite("StreamInfo XML")
struct StreamInfoXMLTests {
    /// Exactly what liblsl 1.17.7 emitted for a five-field stream with metadata.
    static let fullInfo = """
        <?xml version="1.0"?>
        <info>
        \t<name>Demo</name>
        \t<type>EEG</type>
        \t<channel_count>3</channel_count>
        \t<channel_format>float32</channel_format>
        \t<source_id>sid-1</source_id>
        \t<nominal_srate>512.0000000000000</nominal_srate>
        \t<version>1.100000000000000</version>
        \t<created_at>4161370.646552416</created_at>
        \t<uid>a9f3d8fa-8b55-42d6-8d16-1c94599b6bd3</uid>
        \t<session_id>default</session_id>
        \t<hostname>Pekka-IlmarinMBP.local</hostname>
        \t<v4address></v4address>
        \t<v4data_port>16574</v4data_port>
        \t<v4service_port>16572</v4service_port>
        \t<v6address></v6address>
        \t<v6data_port>16574</v6data_port>
        \t<v6service_port>16572</v6service_port>
        \t<desc>
        \t\t<manufacturer>Acme</manufacturer>
        \t\t<channels>
        \t\t\t<channel>
        \t\t\t\t<label>C3</label>
        \t\t\t\t<unit>microvolts</unit>
        \t\t\t</channel>
        \t\t\t<channel>
        \t\t\t\t<label>C4</label>
        \t\t\t\t<unit>microvolts</unit>
        \t\t\t</channel>
        \t\t</channels>
        \t</desc>
        </info>

        """

    @Test("A real liblsl document decodes field for field")
    func decodesLiveDocument() throws {
        let info = try StreamInfoXML.decode(Self.fullInfo)
        #expect(info.name == "Demo")
        #expect(info.type == "EEG")
        #expect(info.channelCount == 3)
        #expect(info.channelFormat == .float32)
        #expect(info.sourceID == "sid-1")
        #expect(info.nominalSampleRate == 512)
        #expect(info.protocolVersion == 110)
        #expect(info.createdAt == 4161370.646552416)
        #expect(info.uid == "a9f3d8fa-8b55-42d6-8d16-1c94599b6bd3")
        #expect(info.sessionID == "default")
        #expect(info.hostname == "Pekka-IlmarinMBP.local")
        #expect(info.v4Address.isEmpty)
        #expect(info.v4DataPort == 16574)
        #expect(info.v4ServicePort == 16572)
        #expect(info.v6DataPort == 16574)
    }

    @Test("The desc subtree is carried through node for node")
    func descTree() throws {
        let info = try StreamInfoXML.decode(Self.fullInfo)
        let desc = try #require(info.desc)
        #expect(desc.childValue("manufacturer") == "Acme")
        let channels = try #require(desc["channels"]).childrenNamed("channel")
        #expect(channels.count == 2)
        #expect(channels[0].childValue("label") == "C3")
        #expect(channels[0].childValue("unit") == "microvolts")
        #expect(channels[1].childValue("label") == "C4")
    }

    @Test("An empty desc becomes nil, as a shortinfo reply always has one")
    func emptyDesc() throws {
        let shortinfo = Self.fullInfo.replacingOccurrences(
            of: Self.fullInfo[Self.fullInfo.range(of: "\t<desc>")!.lowerBound..<Self.fullInfo.range(of: "\t</desc>\n")!.upperBound],
            with: "\t<desc />\n")
        #expect(try StreamInfoXML.decode(shortinfo).desc == nil)
    }

    @Test("Encoding reproduces liblsl's own formatting byte for byte")
    func encodeMatchesReference() throws {
        let info = try StreamInfoXML.decode(Self.fullInfo)
        #expect(StreamInfoXML.encode(info) == Self.fullInfo)
    }

    @Test("Encoding a stream without metadata emits a self-closing desc")
    func encodeWithoutDesc() throws {
        let info = StreamInfo(
            name: "Markers", type: "Markers", channelCount: 1, nominalSampleRate: 0,
            channelFormat: .string, sourceID: "m1", uid: "", sessionID: "", hostname: "")
        let expected = """
            <?xml version="1.0"?>
            <info>
            \t<name>Markers</name>
            \t<type>Markers</type>
            \t<channel_count>1</channel_count>
            \t<channel_format>string</channel_format>
            \t<source_id>m1</source_id>
            \t<nominal_srate>0.000000000000000</nominal_srate>
            \t<version>1.100000000000000</version>
            \t<created_at>0.000000000000000</created_at>
            \t<uid></uid>
            \t<session_id></session_id>
            \t<hostname></hostname>
            \t<v4address></v4address>
            \t<v4data_port>0</v4data_port>
            \t<v4service_port>0</v4service_port>
            \t<v6address></v6address>
            \t<v6data_port>0</v6data_port>
            \t<v6service_port>0</v6service_port>
            \t<desc />
            </info>

            """
        #expect(StreamInfoXML.encode(info) == expected)
    }

    @Test("Doubles are formatted to 16 significant digits with trailing zeros kept")
    func doubleFormatting() {
        // liblsl's locale-independent to_string (`src/util/cast.cpp:9-14`).
        #expect(StreamInfoXML.formatDouble(512) == "512.0000000000000")
        #expect(StreamInfoXML.formatDouble(1.1) == "1.100000000000000")
        #expect(StreamInfoXML.formatDouble(0) == "0.000000000000000")
        #expect(StreamInfoXML.formatDouble(4161370.646552416) == "4161370.646552416")
    }

    @Test("Every channel format token round-trips")
    func channelFormatTokens() throws {
        for format in ChannelFormat.allCases where format != .undefined {
            let info = StreamInfo(name: "S", channelCount: 1, channelFormat: format, uid: "u")
            #expect(try StreamInfoXML.decode(StreamInfoXML.encode(info)).channelFormat == format)
        }
        #expect(ChannelFormat(wireName: "int64") == .int64)
        #expect(ChannelFormat(wireName: "nonsense") == nil)
    }

    @Test("Text is escaped and unescaped")
    func escaping() throws {
        let info = StreamInfo(
            name: "A & B <lab>", type: "\"quoted\"", channelCount: 1, channelFormat: .int8,
            uid: "u")
        let encoded = StreamInfoXML.encode(info)
        #expect(encoded.contains("<name>A &amp; B &lt;lab&gt;</name>"))
        let decoded = try StreamInfoXML.decode(encoded)
        #expect(decoded.name == "A & B <lab>")
        #expect(decoded.type == "\"quoted\"")
    }

    @Test("Documents missing a required field are rejected", arguments: [
        "name", "uid", "channel_format", "channel_count", "version",
    ])
    func requiredFields(field: String) throws {
        let broken = Self.fullInfo.replacingOccurrences(
            of: "<\(field)>", with: "<removed_\(field)>"
        ).replacingOccurrences(of: "</\(field)>", with: "</removed_\(field)>")
        #expect(throws: (any Error).self) { _ = try StreamInfoXML.decode(broken) }
    }

    @Test("Malformed XML is rejected without crashing")
    func malformedXML() {
        for text in ["", "<info>", "not xml at all", "<info><name>x</nam></info>"] {
            #expect(throws: (any Error).self) { _ = try StreamInfoXML.decode(text) }
        }
    }

    @Test("Ports outside 0...65535 are rejected")
    func portRange() {
        let broken = Self.fullInfo.replacingOccurrences(
            of: "<v4data_port>16574</v4data_port>", with: "<v4data_port>99999</v4data_port>")
        #expect(throws: (any Error).self) { _ = try StreamInfoXML.decode(broken) }
    }

    @Test("An out-of-range <version> is rejected, not trapped", arguments: [
        "1e19", "inf", "nan", "-1",
    ])
    func versionRange(value: String) {
        // Peer-supplied: `Int(versionValue * 100)` would abort the process on an
        // oversized finite value or on infinity.
        let broken = Self.fullInfo.replacingOccurrences(
            of: "<version>1.100000000000000</version>",
            with: "<version>\(value)</version>")
        #expect(throws: (any Error).self) { _ = try StreamInfoXML.decode(broken) }
    }

    @Test("A sub-1.10 outlet is identifiable before connecting")
    func oldProtocolVersionVisible() throws {
        // The whole reason protocol 1.00 can be refused early (SCOPE.md §4).
        let old = Self.fullInfo.replacingOccurrences(
            of: "<version>1.100000000000000</version>",
            with: "<version>1.000000000000000</version>")
        #expect(try StreamInfoXML.decode(old).protocolVersion == 100)
    }
}
