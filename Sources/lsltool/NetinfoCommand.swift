import ArgumentParser
import Darwin
import Foundation
import LSL

/// Reports what discovery would send from, and what the local-network probe makes of it
/// (ROADMAP.md step 8).
struct NetinfoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "netinfo",
        abstract: "List the interfaces discovery uses and probe local network access."
    )

    @Option(help: "Seconds to give the local-network probe.")
    var probeTimeout: Double = 2

    @Flag(help: "Do not probe local network access; only enumerate interfaces.")
    var noProbe = false

    func run() async throws {
        Emit.event("ready", ["proto": "none"])

        let interfaces = NetworkInterfaces.all()
        for interface in interfaces {
            Emit.event("interface", Self.fields(of: interface))
        }
        Emit.event(
            "interfaces",
            [
                "count": .int(interfaces.count),
                "discovery_count": .int(interfaces.filter(\.carriesDiscovery).count),
            ])

        if !noProbe {
            let access = await LocalNetwork.probe(timeout: .seconds(probeTimeout))
            Emit.event("access", ["state": .string(String(describing: access))])
        }
    }

    static func fields(of interface: NetworkInterface) -> [String: JSONValue] {
        [
            "name": .string(interface.name),
            "index": .int(Int(interface.index)),
            "family": .string(interface.isIPv6 ? "inet6" : "inet"),
            "address": .string(interface.address.host),
            "broadcast": .string(interface.broadcastAddress?.host ?? ""),
            "functional_type": .string(String(describing: interface.functionalType)),
            "loopback": .bool(interface.isLoopback),
            "discovery": .bool(interface.carriesDiscovery),
        ]
    }
}
