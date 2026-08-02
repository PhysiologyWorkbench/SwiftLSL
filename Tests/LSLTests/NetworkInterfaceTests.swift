import Darwin
import Foundation
import Testing

@testable import LSL

@Suite("Interface enumeration")
struct NetworkInterfaceTests {
    @Test("The loopback interface is enumerated and classified by ioctl, not by name")
    func loopback() {
        let interfaces = NetworkInterfaces.all()
        let loopback = interfaces.filter(\.isLoopback)
        #expect(!loopback.isEmpty, "every host has a loopback interface")
        #expect(loopback.allSatisfy { $0.functionalType == .loopback })
        #expect(loopback.contains { $0.address.host == "127.0.0.1" })
        #expect(loopback.allSatisfy { $0.index != 0 })
    }

    @Test("The functional-type ioctl request number matches <net/if.h>")
    func ioctlRequest() {
        // _IOWR('i', 173, struct ifreq) with sizeof(struct ifreq) == 32; the Darwin headers
        // do not export SIOCGIFFUNCTIONALTYPE to Swift, so the encoding is spelt out here.
        let inOut: UInt = 0xc000_0000
        let expected = inOut | (32 << 16) | (UInt(UInt8(ascii: "i")) << 8) | 173
        #expect(NetworkInterfaces.functionalTypeRequest == expected)
        #expect(MemoryLayout<ifreq>.size == 32)
    }

    @Test("A scoped IPv6 address is unpacked from its KAME form")
    func kameScope() {
        // getifaddrs hides the interface index inside bytes 2-3 of a link-local address and
        // leaves sin6_scope_id zero. Unpacked, it must read back as fe80::…%name.
        let scoped = NetworkInterfaces.all().filter {
            $0.isIPv6 && $0.address.host.hasPrefix("fe80::")
        }
        for interface in scoped {
            #expect(interface.address.scopeID == interface.index)
            #expect(interface.address.host.hasSuffix("%" + interface.name))
        }
    }

    @Test("Peer-to-peer and point-to-point links do not carry discovery")
    func discoveryFilter() {
        for interface in NetworkInterfaces.all() {
            if interface.functionalType == .wifiAWDL || interface.functionalType == .cellular {
                #expect(!interface.carriesDiscovery)
            }
            if interface.flags & UInt32(IFF_POINTOPOINT) != 0 {
                #expect(!interface.carriesDiscovery, "a VPN tunnel is not a local network")
            }
            if interface.carriesDiscovery {
                #expect(interface.flags & UInt32(IFF_UP) != 0)
                #expect(interface.flags & UInt32(IFF_MULTICAST) != 0)
            }
        }
    }

    @Test("Discovery interfaces are filtered by address family")
    func familyFilter() {
        #expect(NetworkInterfaces.forDiscovery(family: sa_family_t(AF_INET)).allSatisfy {
            !$0.isIPv6
        })
        #expect(NetworkInterfaces.forDiscovery(family: sa_family_t(AF_INET6)).allSatisfy {
            $0.isIPv6
        })
    }
}

@Suite("Per-interface discovery targets")
struct InterfaceTargetTests {
    static func interface(
        address: String, index: UInt32, broadcast: String? = nil
    ) -> NetworkInterface {
        NetworkInterface(
            name: "test\(index)", index: index,
            address: SocketAddress(numericHost: address, port: 0)!,
            broadcastAddress: broadcast.flatMap { SocketAddress(numericHost: $0, port: 0) },
            functionalType: .wired, flags: UInt32(IFF_UP | IFF_BROADCAST | IFF_MULTICAST))
    }

    @Test("IPv6 groups are scoped to the interface they leave by")
    func scopesIPv6Groups() {
        // An unscoped FF02: group is not routable at all (SCOPE.md §8.5).
        let resolver = StreamResolver()
        let sent = resolver.targets(
            [SocketAddress(numericHost: "FF02:\(ResolveScope.ipv6MulticastGroup)", port: 16571)!],
            via: Self.interface(address: "fe80::1", index: 7))
        #expect(sent.count == 1)
        #expect(sent[0].scopeID == 7)
    }

    @Test("The interface's directed broadcast is added at the multicast port")
    func addsDirectedBroadcast() {
        // IP_MULTICAST_IF does not steer a broadcast: 255.255.255.255 follows the default
        // route whichever interface is selected.
        let resolver = StreamResolver()
        let sent = resolver.targets(
            [SocketAddress(numericHost: "255.255.255.255", port: 16571)!],
            via: Self.interface(address: "192.0.2.10", index: 3, broadcast: "192.0.2.255"))
        #expect(sent.map(\.host) == ["255.255.255.255", "192.0.2.255"])
        #expect(sent.allSatisfy { $0.port == 16571 })
    }

    @Test("An interface without a broadcast address contributes no extra target")
    func withoutBroadcast() {
        let resolver = StreamResolver()
        let sent = resolver.targets(
            [SocketAddress(numericHost: "224.0.0.1", port: 16571)!],
            via: Self.interface(address: "192.0.2.10", index: 3))
        #expect(sent.map(\.host) == ["224.0.0.1"])
    }
}

@Suite("Local network probe")
struct LocalNetworkProbeTests {
    @Test("The probe answers within its timeout")
    func answers() async {
        let state = await LocalNetwork.probe(timeout: .seconds(2))
        // A terminal process on a desktop is granted local network access unconditionally,
        // so only `.denied` is out of reach there; the checklist covers that case. A
        // headless session has no such grant and the probe does report `.denied`, even
        // though BSD-socket discovery keeps working (SCOPE.md §8.3).
        if ProcessInfo.processInfo.environment["CI"] != nil { return }
        #expect(state == .allowed || state == .unknown)
    }
}
