import Darwin
import Foundation
import LSLCore

/// One address of one local interface, as reported by `getifaddrs`.
///
/// An interface with both an IPv4 and an IPv6 address appears twice: the outbound-interface
/// socket option is set from the address for IPv4 and from the index for IPv6, so the pair
/// is what the send loop actually needs (SCOPE.md §8.5).
public struct NetworkInterface: Sendable, Hashable {
    /// The `SIOCGIFFUNCTIONALTYPE` classification. BSD names such as `en0` "aren't
    /// considered API on any Apple platform" (TN3179), so this — never the name — is what
    /// decides whether discovery goes out of an interface.
    public enum FunctionalType: UInt32, Sendable {
        case unknown = 0
        case loopback = 1
        case wired = 2
        case wifi = 3
        /// Apple Wireless Direct Link. Peer-to-peer, not a local network; never used here.
        case wifiAWDL = 4
        case cellular = 5
        /// An internal link to a coprocessor (`anpi*`).
        case coprocessor = 6
        /// The Watch/companion-device link (`llw0`).
        case companionLink = 7
    }

    /// The BSD name, `en0` and such. Diagnostic only — never branch on it.
    public let name: String
    /// The kernel interface index, which is what `IPV6_MULTICAST_IF` and an IPv6 scope
    /// id take.
    public let index: UInt32
    /// This interface's own address, and what `IP_MULTICAST_IF` takes for IPv4.
    public let address: SocketAddress
    /// The interface's directed broadcast address, IPv4 only.
    public let broadcastAddress: SocketAddress?
    public let functionalType: FunctionalType
    /// The raw `ifa_flags` word: `IFF_UP`, `IFF_MULTICAST`, `IFF_LOOPBACK` and friends.
    public let flags: UInt32

    public var isIPv6: Bool { address.isIPv6 }
    public var isLoopback: Bool { flags & UInt32(IFF_LOOPBACK) != 0 }

    /// Whether discovery queries should be sent out of this interface.
    ///
    /// `liblsl` filters on `IFF_UP | IFF_MULTICAST` alone
    /// (`src/netinterfaces.cpp:92-97`). Two further exclusions are Apple-specific: AWDL and
    /// the companion link are peer-to-peer links rather than local networks, and cellular
    /// and VPN interfaces "are not local networks" and are not broadcast-capable
    /// (TN3179, *Local network operations*; SCOPE.md §8.2).
    public var carriesDiscovery: Bool {
        guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_MULTICAST) != 0 else { return false }
        guard flags & UInt32(IFF_POINTOPOINT) == 0 else { return false }
        switch functionalType {
        case .loopback, .wired, .wifi, .unknown: return true
        case .wifiAWDL, .cellular, .coprocessor, .companionLink: return false
        }
    }
}

/// Enumerates the local interfaces a discovery wave should be sent from.
public enum NetworkInterfaces {
    /// `_IOWR('i', 173, struct ifreq)`, which the Darwin headers do not export to Swift.
    /// Verified against `<net/if.h>` on macOS 26: `0xc02069ad`, `sizeof(struct ifreq) == 32`.
    static let functionalTypeRequest: UInt = 0xc020_69ad

    /// Every address of every interface, unfiltered.
    public static func all() -> [NetworkInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return [] }
        defer { freeifaddrs(head) }

        // One socket serves every ioctl; the family it was opened with is irrelevant.
        let probe = socket(AF_INET, SOCK_DGRAM, 0)
        defer { if probe >= 0 { _ = Darwin.close(probe) } }

        var interfaces: [NetworkInterface] = []
        var types: [String: NetworkInterface.FunctionalType] = [:]
        for entry in sequence(first: head, next: { $0.pointee.ifa_next }) {
            guard let raw = entry.pointee.ifa_addr else { continue }
            let family = raw.pointee.sa_family
            guard family == sa_family_t(AF_INET) || family == sa_family_t(AF_INET6) else {
                continue
            }
            let name = String(cString: entry.pointee.ifa_name)
            guard let address = SocketAddress(sockaddr: raw) else { continue }

            var broadcast: SocketAddress?
            if family == sa_family_t(AF_INET), entry.pointee.ifa_flags & UInt32(IFF_BROADCAST) != 0,
                let raw = entry.pointee.ifa_dstaddr
            {
                broadcast = SocketAddress(sockaddr: raw)
            }

            let type: NetworkInterface.FunctionalType
            if let known = types[name] {
                type = known
            } else {
                type = functionalType(of: name, using: probe)
                types[name] = type
            }

            interfaces.append(
                NetworkInterface(
                    name: name,
                    index: if_nametoindex(name),
                    address: address,
                    broadcastAddress: broadcast,
                    functionalType: type,
                    flags: entry.pointee.ifa_flags))
        }
        return interfaces
    }

    /// The interfaces a discovery wave is sent from, for one address family.
    public static func forDiscovery(family: sa_family_t) -> [NetworkInterface] {
        let wantsIPv6 = family == sa_family_t(AF_INET6)
        return all().filter { $0.carriesDiscovery && $0.isIPv6 == wantsIPv6 }
    }

    private static func functionalType(of name: String, using probe: Int32)
        -> NetworkInterface.FunctionalType
    {
        guard probe >= 0 else { return .unknown }
        var request = ifreq()
        withUnsafeMutableBytes(of: &request.ifr_name) { field in
            for (offset, byte) in name.utf8.enumerated() where offset < field.count - 1 {
                field[offset] = byte
            }
        }
        guard ioctl(probe, functionalTypeRequest, &request) == 0 else { return .unknown }
        // The reply lands in the `ifr_ifru` union, whose Swift projection is the `ifru_flags`
        // Int16 pair rather than the u_int32_t this ioctl writes.
        let raw = withUnsafeBytes(of: &request.ifr_ifru) { $0.loadUnaligned(as: UInt32.self) }
        return NetworkInterface.FunctionalType(rawValue: raw) ?? .unknown
    }
}
