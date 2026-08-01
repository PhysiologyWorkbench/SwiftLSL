import Foundation
import LSLCore

/// Which addresses a resolve is sent to, and how far its packets travel.
///
/// The sets are cumulative and each level raises the TTL (SCOPE.md §2.1,
/// `src/api_config.cpp:188-263`). Note the documentation and the source disagree about
/// `MachineAddresses`; the source is authoritative (SCOPE.md gap #13).
public struct ResolveScope: Sendable, Hashable {
    public let addresses: [String]
    public let ttl: Int

    public init(addresses: [String], ttl: Int) {
        self.addresses = addresses
        self.ttl = ttl
    }

    /// The IPv6 group prefix per scope is composed as `FF0x:` + this suffix.
    public static let ipv6MulticastGroup = "113D:6FDD:2C17:A643:FFE2:1BD1:3CD2"

    public static let machine = ResolveScope(addresses: ["127.0.0.1"], ttl: 0)

    public static let link = ResolveScope(
        addresses: machine.addresses + [
            "255.255.255.255", "224.0.0.1", "224.0.0.183", "FF02:\(ipv6MulticastGroup)",
        ],
        ttl: 1
    )

    public static let site = ResolveScope(
        addresses: link.addresses + ["239.255.172.215", "FF05:\(ipv6MulticastGroup)"],
        ttl: 24
    )

    public static let organization = ResolveScope(
        addresses: site.addresses + ["FF08:\(ipv6MulticastGroup)"],
        ttl: 32
    )

    public static let global = ResolveScope(
        addresses: organization.addresses + ["FF0E:\(ipv6MulticastGroup)"],
        ttl: 255
    )

    public static func custom(addresses: [String], ttl: Int) -> ResolveScope {
        ResolveScope(addresses: addresses, ttl: ttl)
    }
}

/// The same knobs as `lsl_api.cfg`, with the same defaults. Reading the config *file* is
/// deferred (SCOPE.md §3); nothing here precludes adding it.
public struct ResolverConfiguration: Sendable {
    public var scope: ResolveScope = .site
    public var sessionID = "default"
    /// Hosts queried by unicast across the whole port range, bypassing multicast entirely.
    /// This path needs no iOS multicast entitlement at all (SCOPE.md §8.1).
    public var knownPeers: [String] = []
    /// Set to false to reach outlets only through `knownPeers`.
    public var useMulticast = true

    public var multicastPort: UInt16 = 16571
    public var basePort: UInt16 = 16572
    public var portRange: UInt16 = 32

    public var allowIPv4 = true
    public var allowIPv6 = true

    /// `tuning.MulticastMinRTT` — how long a multicast wave is given before the unicast
    /// burst and the next wave (`src/api_config.cpp:307`).
    public var multicastMinRTT: Duration = .milliseconds(500)
    /// `tuning.UnicastMinRTT` (`src/api_config.cpp:309`).
    public var unicastMinRTT: Duration = .milliseconds(750)
    /// `tuning.ContinuousResolveInterval` — added between waves outside fast mode
    /// (`src/api_config.cpp:311`).
    public var continuousResolveInterval: Duration = .milliseconds(500)

    public init() {}

    /// The multicast and broadcast targets of the configured scope, as addresses.
    func multicastTargets() -> [SocketAddress] {
        guard useMulticast else { return [] }
        return scope.addresses.compactMap {
            SocketAddress(numericHost: $0, port: multicastPort)
        }.filter { allow($0) }
    }

    /// Every `knownPeers` host across `basePort ..< basePort + portRange`
    /// (`src/resolver_impl.cpp:36-47`).
    func unicastTargets() -> [SocketAddress] {
        knownPeers.flatMap { peer -> [SocketAddress] in
            let resolved = SocketAddress.resolve(host: peer, port: basePort).filter { allow($0) }
            // getaddrinfo returns one entry per address; the port range is enumerated on
            // top of each of them.
            var uniqueHosts: [String] = []
            for address in resolved where !uniqueHosts.contains(address.host) {
                uniqueHosts.append(address.host)
            }
            return uniqueHosts.flatMap { host in
                (basePort..<(basePort &+ portRange)).compactMap {
                    SocketAddress(numericHost: host, port: $0)
                }
            }
        }
    }

    private func allow(_ address: SocketAddress) -> Bool {
        address.isIPv6 ? allowIPv6 : allowIPv4
    }
}
