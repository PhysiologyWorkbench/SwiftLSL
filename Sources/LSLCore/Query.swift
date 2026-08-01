/// XPath 1.0 predicates the *outlet* evaluates against its `<info>` element. The inlet
/// only ever builds these strings; it never evaluates one (SCOPE.md §1, §2.1).
public enum Query {
    /// A resolve is always scoped to a session, as `liblsl` does
    /// (`src/resolver_impl.cpp:66-73`).
    public static func session(_ sessionID: String, and predicate: String? = nil) -> String {
        let base = "session_id='\(escape(sessionID))'"
        guard let predicate, !predicate.isEmpty else { return base }
        return "\(base) and \(predicate)"
    }

    public static func property(_ name: String, equals value: String) -> String {
        "\(name)='\(escape(value))'"
    }

    /// The query used to find a lost stream again.
    ///
    /// `nominal_srate` is deliberately excluded: `str2double(double2str(x)) == x` is not
    /// reliable, and a stream that fails to match would never be recovered
    /// (SCOPE.md gap #16, `src/inlet_connection.cpp:154-174`).
    public static func recovery(for info: StreamInfo) -> String {
        var parts = ["channel_count='\(info.channelCount)'"]
        if !info.name.isEmpty { parts.append(property("name", equals: info.name)) }
        if !info.type.isEmpty { parts.append(property("type", equals: info.type)) }
        if !info.sourceID.isEmpty { parts.append(property("source_id", equals: info.sourceID)) }
        parts.append(property("channel_format", equals: info.channelFormat.wireName))
        return parts.joined(separator: " and ")
    }

    /// An XPath 1.0 string literal cannot contain the quote that delimits it and has no
    /// escape syntax, so a value containing `'` cannot be expressed. Dropping the quote
    /// keeps the predicate well-formed; `liblsl` interpolates blindly and produces a query
    /// the outlet then rejects as malformed.
    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "")
    }
}
