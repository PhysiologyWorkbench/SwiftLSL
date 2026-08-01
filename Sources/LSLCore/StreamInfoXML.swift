import Foundation

/// StreamInfo XML, as produced and consumed by `liblsl`'s `stream_info_impl`
/// (SCOPE.md §2.4). `XMLParser` is used because `XMLDocument` is macOS-only; no XPath is
/// needed anywhere on the inlet side (SCOPE.md §1).
public enum StreamInfoXML {
    /// Parses a `<info>` document. `<desc>` is carried through as a generic tree, and is
    /// `nil` when the element is absent or empty — a shortinfo reply always has an empty
    /// one.
    public static func decode(_ xml: Data) throws -> StreamInfo {
        let root = try parseTree(xml)
        guard let info = root.name == "info" ? root : root["info"] else {
            throw LSLError.invalidStreamInfo("no <info> element")
        }
        return try decode(info)
    }

    public static func decode(_ xml: String) throws -> StreamInfo {
        try decode(Data(xml.utf8))
    }

    public static func decode(_ info: MetadataElement) throws -> StreamInfo {
        let name = info.childValue("name")
        guard !name.isEmpty else {
            throw LSLError.invalidStreamInfo("empty <name>")
        }
        let uid = info.childValue("uid")
        guard !uid.isEmpty else {
            throw LSLError.invalidStreamInfo("empty <uid>")
        }
        let formatToken = info.childValue("channel_format")
        guard let format = ChannelFormat(wireName: formatToken) else {
            throw LSLError.invalidStreamInfo("invalid channel format \(formatToken)")
        }
        let channelCount = try nonNegativeInteger(info, "channel_count")
        let sampleRate = try nonNegativeDouble(info, "nominal_srate")

        // <version> is written as version/100 and read back as stod(...)*100, truncated
        // (`src/stream_info_impl.cpp:132`). 1.1 becomes 110.
        guard let versionValue = Double(info.childValue("version")), versionValue > 0 else {
            throw LSLError.invalidStreamInfo("invalid <version>")
        }
        let desc = info["desc"]

        return StreamInfo(
            name: name,
            type: info.childValue("type"),
            channelCount: channelCount,
            nominalSampleRate: sampleRate,
            channelFormat: format,
            sourceID: info.childValue("source_id"),
            uid: uid,
            sessionID: info.childValue("session_id"),
            hostname: info.childValue("hostname"),
            createdAt: Double(info.childValue("created_at")) ?? 0,
            protocolVersion: Int(versionValue * 100),
            v4Address: info.childValue("v4address"),
            v4DataPort: try port(info, "v4data_port"),
            v4ServicePort: try port(info, "v4service_port"),
            v6Address: info.childValue("v6address"),
            v6DataPort: try port(info, "v6data_port"),
            v6ServicePort: try port(info, "v6service_port"),
            desc: (desc?.children.isEmpty ?? true) ? nil : desc
        )
    }

    /// Renders the document `liblsl` would render for this info, in its field order and
    /// with its `pugixml` formatting: an XML declaration, tab indentation, and an empty
    /// `<desc />` when there is no metadata.
    public static func encode(_ info: StreamInfo, includeDesc: Bool = true) -> String {
        var lines = ["<?xml version=\"1.0\"?>", "<info>"]
        func field(_ name: String, _ value: String) {
            lines.append("\t<\(name)>\(escape(value))</\(name)>")
        }
        field("name", info.name)
        field("type", info.type)
        field("channel_count", String(info.channelCount))
        field("channel_format", info.channelFormat.wireName)
        field("source_id", info.sourceID)
        field("nominal_srate", formatDouble(info.nominalSampleRate))
        field("version", formatDouble(Double(info.protocolVersion) / 100))
        field("created_at", formatDouble(info.createdAt))
        field("uid", info.uid)
        field("session_id", info.sessionID)
        field("hostname", info.hostname)
        field("v4address", info.v4Address)
        field("v4data_port", String(info.v4DataPort))
        field("v4service_port", String(info.v4ServicePort))
        field("v6address", info.v6Address)
        field("v6data_port", String(info.v6DataPort))
        field("v6service_port", String(info.v6ServicePort))
        if includeDesc, let desc = info.desc, !desc.children.isEmpty {
            lines.append(contentsOf: render(desc, indent: 1))
        } else {
            lines.append("\t<desc />")
        }
        lines.append("</info>")
        return lines.joined(separator: "\n") + "\n"
    }

    /// `liblsl`'s locale-independent double formatting: 16 significant digits, trailing
    /// zeros kept (`src/util/cast.cpp:9-14`).
    public static func formatDouble(_ value: Double) -> String {
        String(format: "%#.16g", value)
    }

    // MARK: - Generic tree

    public static func parseTree(_ xml: Data) throws -> MetadataElement {
        let parser = XMLParser(data: xml)
        let builder = TreeBuilder()
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            let reason = builder.failure ?? parser.parserError.map { "\($0)" } ?? "unparseable XML"
            throw LSLError.invalidStreamInfo(reason)
        }
        return root
    }

    private static func render(_ element: MetadataElement, indent: Int) -> [String] {
        let pad = String(repeating: "\t", count: indent)
        if element.children.isEmpty {
            guard let value = element.value, !value.isEmpty else {
                return ["\(pad)<\(element.name) />"]
            }
            return ["\(pad)<\(element.name)>\(escape(value))</\(element.name)>"]
        }
        var lines = ["\(pad)<\(element.name)>"]
        for child in element.children {
            lines.append(contentsOf: render(child, indent: indent + 1))
        }
        lines.append("\(pad)</\(element.name)>")
        return lines
    }

    private static func escape(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            default: escaped.append(character)
            }
        }
        return escaped
    }

    private static func nonNegativeInteger(_ info: MetadataElement, _ field: String) throws -> Int {
        guard let value = Int(info.childValue(field)), value >= 0 else {
            throw LSLError.invalidStreamInfo("\(field) must be a non-negative integer")
        }
        return value
    }

    private static func nonNegativeDouble(_ info: MetadataElement, _ field: String) throws -> Double {
        guard let value = Double(info.childValue(field)), value >= 0 else {
            throw LSLError.invalidStreamInfo("\(field) must be a non-negative number")
        }
        return value
    }

    private static func port(_ info: MetadataElement, _ field: String) throws -> UInt16 {
        let text = info.childValue(field)
        guard let value = Int(text), (0...65535).contains(value) else {
            throw LSLError.invalidStreamInfo("\(field) must be in 0...65535, got \(text)")
        }
        return UInt16(value)
    }
}

/// Builds a `MetadataElement` tree from SAX events. Character data is kept verbatim for leaf
/// elements and discarded for elements with children, where it is only the writer's
/// indentation.
private final class TreeBuilder: NSObject, XMLParserDelegate {
    private struct Frame {
        let name: String
        var text = ""
        var children: [MetadataElement] = []
    }

    private var stack: [Frame] = []
    fileprivate var root: MetadataElement?
    fileprivate var failure: String?

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName: String?, attributes: [String: String]
    ) {
        stack.append(Frame(name: elementName))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].text += string
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName: String?
    ) {
        guard let frame = stack.popLast() else { return }
        let element = MetadataElement(
            name: frame.name,
            value: frame.children.isEmpty ? frame.text : nil,
            children: frame.children
        )
        if stack.isEmpty {
            root = element
        } else {
            stack[stack.count - 1].children.append(element)
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: any Error) {
        failure = "\(parseError)"
    }
}
