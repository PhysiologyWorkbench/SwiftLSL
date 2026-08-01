/// A generic XML element tree.
///
/// `<desc>` has no schema — the paper points at an external wiki for content-type
/// nomenclature (SCOPE.md §12 item 7) — so it is parsed as a plain tree and left for the
/// consumer to interpret.
public struct XMLElement: Sendable, Hashable {
    public let name: String
    /// Character data of a leaf element. Always `nil` for an element with children: the
    /// only text such an element carries is the writer's indentation.
    public let value: String?
    public let children: [XMLElement]

    public init(name: String, value: String? = nil, children: [XMLElement] = []) {
        self.name = name
        self.value = value
        self.children = children
    }

    /// The first child with this name, matching `pugixml`'s `child()`.
    public subscript(childName: String) -> XMLElement? {
        children.first { $0.name == childName }
    }

    /// The first child's character data, or `""` — matching `pugixml`'s `child_value()`,
    /// which is what `liblsl` reads every StreamInfo field with.
    public func childValue(_ childName: String) -> String {
        self[childName]?.value ?? ""
    }

    public func childrenNamed(_ childName: String) -> [XMLElement] {
        children.filter { $0.name == childName }
    }
}
