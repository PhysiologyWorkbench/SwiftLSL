import ArgumentParser
import Foundation
import LSL

/// Fetches and emits the full StreamInfo, `<desc>` included (ROADMAP.md step 5).
struct InfoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Fetch a stream's full metadata over LSL:fullinfo."
    )

    @Option(help: "Outlet host.")
    var host: String

    @Option(help: "Outlet data port.")
    var port: UInt16

    @Option(help: "How many times to retry an invalid response.")
    var attempts: Int = 3

    func run() async throws {
        Termination.exitOnSIGTERM()

        let info = try await MetadataFetcher.fetch(
            host: host, port: port, attempts: attempts)

        var fields = ResolveCommand.fields(of: info)
        fields["created_at"] = .double(info.createdAt)
        fields["desc"] = info.desc.map(Self.tree) ?? .null
        Emit.event("info", fields)
    }

    /// The `<desc>` subtree, node for node. It has no schema — the package parses it as a
    /// generic tree and leaves interpretation to the consumer (SCOPE.md §12 item 7).
    static func tree(_ element: MetadataElement) -> JSONValue {
        .object([
            "name": .string(element.name),
            "value": element.value.map { .string($0) } ?? .null,
            "children": .array(element.children.map(tree)),
        ])
    }
}
