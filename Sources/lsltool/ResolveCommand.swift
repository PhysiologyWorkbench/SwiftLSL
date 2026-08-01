import ArgumentParser
import Foundation
import LSL

/// Runs a resolve and emits one event per discovered stream (ROADMAP.md step 3).
struct ResolveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "resolve",
        abstract: "Discover LSL streams and emit one event per stream."
    )

    @Option(help: "XPath predicate, e.g. \"type='EEG'\". Session scoping is added for you.")
    var query: String?

    @Option(help: "Seconds to keep resolving.")
    var timeout: Double = 2

    @Option(help: "Stop early once this many streams have answered.")
    var minimum: Int?

    @Option(name: .customLong("known-peer"), help: "Query this host by unicast. Repeatable.")
    var knownPeers: [String] = []

    @Flag(help: "Do not send to any multicast or broadcast address.")
    var noMulticast = false

    @Option(help: "Resolve scope: machine, link, site, organization or global.")
    var scope: String = "site"

    @Option(help: "Session id to scope the query to.")
    var session: String = "default"

    @Flag(help: "Keep resolving and emit the set on every change, until SIGTERM.")
    var continuous = false

    @Option(help: "Seconds without a reply after which a stream is forgotten.")
    var forgetAfter: Double = 5

    func run() async throws {
        Termination.exitOnSIGTERM()

        var settings = ResolverConfiguration()
        settings.scope = try Self.scope(named: scope)
        settings.sessionID = session
        settings.knownPeers = knownPeers
        settings.useMulticast = !noMulticast

        let resolver = StreamResolver(configuration: settings)
        Emit.event(
            "ready",
            [
                "proto": "udp",
                "scope": .string(scope),
                "query": .string(Query.session(session, and: query)),
            ])

        if continuous {
            for await streams in resolver.continuousResolve(
                query: query, forgetAfter: .seconds(forgetAfter))
            {
                Emit.event("streams", ["count": .int(streams.count)])
                for stream in streams { Emit.event("stream", Self.fields(of: stream)) }
            }
        } else {
            let streams = try await resolver.resolve(
                query: query, minimum: minimum, timeout: .seconds(timeout))
            for stream in streams { Emit.event("stream", Self.fields(of: stream)) }
            Emit.event("done", ["count": .int(streams.count)])
        }
    }

    static func scope(named name: String) throws -> ResolveScope {
        switch name {
        case "machine": .machine
        case "link": .link
        case "site": .site
        case "organization": .organization
        case "global": .global
        default: throw ToolError("unknown resolve scope '\(name)'")
        }
    }

    static func fields(of stream: StreamInfo) -> [String: JSONValue] {
        [
            "name": .string(stream.name),
            "type": .string(stream.type),
            "uid": .string(stream.uid),
            "source_id": .string(stream.sourceID),
            "session_id": .string(stream.sessionID),
            "hostname": .string(stream.hostname),
            "channel_count": .int(stream.channelCount),
            "channel_format": .string(stream.channelFormat.wireName),
            "nominal_srate": .double(stream.nominalSampleRate),
            "protocol_version": .int(stream.protocolVersion),
            "v4address": .string(stream.v4Address),
            "v4data_port": .int(Int(stream.v4DataPort)),
            "v4service_port": .int(Int(stream.v4ServicePort)),
            "v6address": .string(stream.v6Address),
            "v6data_port": .int(Int(stream.v6DataPort)),
            "v6service_port": .int(Int(stream.v6ServicePort)),
        ]
    }
}
