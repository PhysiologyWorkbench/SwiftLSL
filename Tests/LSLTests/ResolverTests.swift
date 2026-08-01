import Darwin
import Foundation
import Testing

@testable import LSL

@Suite("Resolve scopes and targets")
struct ResolveScopeTests {
    @Test("Scope address sets are cumulative with the documented TTLs")
    func scopeSets() {
        // SCOPE.md §2.1, `src/api_config.cpp:188-263`.
        #expect(ResolveScope.machine.addresses == ["127.0.0.1"])
        #expect(ResolveScope.machine.ttl == 0)

        #expect(ResolveScope.link.ttl == 1)
        #expect(ResolveScope.link.addresses.contains("255.255.255.255"))
        #expect(ResolveScope.link.addresses.contains("224.0.0.1"))
        #expect(ResolveScope.link.addresses.contains("224.0.0.183"))
        #expect(ResolveScope.link.addresses.first == "127.0.0.1")

        #expect(ResolveScope.site.ttl == 24)
        #expect(ResolveScope.site.addresses.contains("239.255.172.215"))
        #expect(ResolveScope.site.addresses.starts(with: ResolveScope.link.addresses))

        #expect(ResolveScope.organization.ttl == 32)
        #expect(ResolveScope.global.ttl == 255)
    }

    @Test("IPv6 groups are composed per scope from one suffix")
    func ipv6Groups() {
        let suffix = ResolveScope.ipv6MulticastGroup
        #expect(suffix == "113D:6FDD:2C17:A643:FFE2:1BD1:3CD2")
        #expect(ResolveScope.link.addresses.contains("FF02:\(suffix)"))
        #expect(ResolveScope.site.addresses.contains("FF05:\(suffix)"))
        #expect(ResolveScope.organization.addresses.contains("FF08:\(suffix)"))
        #expect(ResolveScope.global.addresses.contains("FF0E:\(suffix)"))
    }

    @Test("Multicast targets carry the multicast port and honour the IP-version switches")
    func multicastTargets() {
        var settings = ResolverConfiguration()
        settings.scope = .site
        let all = settings.multicastTargets()
        #expect(all.allSatisfy { $0.port == 16571 })
        #expect(all.contains { $0.isIPv6 })
        #expect(all.contains { !$0.isIPv6 })

        settings.allowIPv6 = false
        #expect(settings.multicastTargets().allSatisfy { !$0.isIPv6 })

        settings.allowIPv6 = true
        settings.allowIPv4 = false
        #expect(settings.multicastTargets().allSatisfy { $0.isIPv6 })

        settings.allowIPv4 = true
        settings.useMulticast = false
        #expect(settings.multicastTargets().isEmpty)
    }

    @Test("Known peers are enumerated across the whole port range")
    func unicastTargets() {
        // `src/resolver_impl.cpp:36-47`: each peer × BasePort ..< BasePort + PortRange.
        var settings = ResolverConfiguration()
        settings.knownPeers = ["127.0.0.1"]
        let targets = settings.unicastTargets()
        #expect(targets.count == 32)
        #expect(targets.map(\.port).min() == 16572)
        #expect(targets.map(\.port).max() == 16603)
        #expect(targets.allSatisfy { $0.host == "127.0.0.1" })
    }

    @Test("A peer that does not resolve contributes no targets")
    func unresolvablePeer() {
        var settings = ResolverConfiguration()
        settings.knownPeers = ["no-such-host.invalid"]
        #expect(settings.unicastTargets().isEmpty)
    }
}

@Suite("Resolve session")
struct ResolveSessionTests {
    static func info(uid: String, name: String = "S") -> StreamInfo {
        StreamInfo(name: name, channelCount: 1, channelFormat: .float32, uid: uid)
    }

    static func address(_ host: String, _ port: UInt16 = 16572) -> SocketAddress {
        SocketAddress(numericHost: host, port: port)!
    }

    @Test("The first responder's address is kept when a second peer answers")
    func firstResponderWins() async {
        // `src/resolve_attempt_udp.cpp:121-141` — the earlier record is assumed to be the
        // faster route, so its address is never overwritten.
        let session = ResolveSession()
        await session.record(Self.info(uid: "u1"), from: Self.address("127.0.0.1"))
        await session.record(Self.info(uid: "u1"), from: Self.address("192.0.2.7"))

        let streams = await session.snapshot()
        #expect(streams.count == 1)
        #expect(streams[0].v4Address == "127.0.0.1")
    }

    @Test("An address is recorded per family")
    func perFamilyAddresses() async {
        let session = ResolveSession()
        await session.record(Self.info(uid: "u1"), from: Self.address("127.0.0.1"))
        await session.record(Self.info(uid: "u1"), from: Self.address("::1"))

        let streams = await session.snapshot()
        #expect(streams[0].v4Address == "127.0.0.1")
        #expect(streams[0].v6Address == "::1")
    }

    @Test("An address the outlet advertised itself is not replaced")
    func advertisedAddressKept() async {
        let session = ResolveSession()
        var advertised = Self.info(uid: "u1")
        advertised.v4Address = "10.0.0.4"
        await session.record(advertised, from: Self.address("127.0.0.1"))
        #expect(await session.snapshot()[0].v4Address == "10.0.0.4")
    }

    @Test("Distinct UIDs are distinct streams")
    func distinctUIDs() async {
        let session = ResolveSession()
        await session.record(Self.info(uid: "u1"), from: Self.address("127.0.0.1"))
        await session.record(Self.info(uid: "u2"), from: Self.address("127.0.0.1"))
        #expect(await session.snapshot().count == 2)
    }

    @Test("Waiting for a count returns as soon as it is reached")
    func waitForCount() async {
        let session = ResolveSession()
        await session.record(Self.info(uid: "u1"), from: Self.address("127.0.0.1"))
        await session.waitForCount(1)

        async let waiter: Void = session.waitForCount(2)
        await session.record(Self.info(uid: "u2"), from: Self.address("127.0.0.1"))
        await waiter
        #expect(await session.snapshot().count == 2)
    }

    @Test("Changes are published once per newly discovered stream")
    func changesPublished() async {
        let session = ResolveSession()
        let stream = await session.changes()
        let collector = Task {
            var seen: [Int] = []
            for await snapshot in stream {
                seen.append(snapshot.count)
                if snapshot.count == 2 { break }
            }
            return seen
        }
        await session.record(Self.info(uid: "u1"), from: Self.address("127.0.0.1"))
        // A repeat reply for a known stream refreshes it without republishing.
        await session.record(Self.info(uid: "u1"), from: Self.address("127.0.0.1"))
        await session.record(Self.info(uid: "u2"), from: Self.address("127.0.0.1"))
        #expect(await collector.value == [0, 1, 2])
    }
}

@Suite("Datagram endpoint")
struct DatagramEndpointTests {
    @Test("Binding prefers the 16572..16603 range")
    func prefersPortRange() throws {
        let endpoint = try DatagramEndpoint(family: sa_family_t(AF_INET))
        defer { endpoint.close() }
        #expect((16572...16603).contains(endpoint.boundPort))
    }

    @Test("An inlet has no port-range requirement")
    func fallsBackToAnyPort() throws {
        // The port it listens on travels in the query itself (SCOPE.md gap #17).
        let endpoint = try DatagramEndpoint(family: sa_family_t(AF_INET), port: 0)
        defer { endpoint.close() }
        #expect(endpoint.boundPort > 0)
    }

    @Test("Datagrams round-trip with their source address")
    func roundTrip() async throws {
        let receiver = try DatagramEndpoint(family: sa_family_t(AF_INET), port: 0)
        defer { receiver.close() }
        let sender = try DatagramEndpoint(family: sa_family_t(AF_INET), port: 0)
        defer { sender.close() }

        let destination = SocketAddress(numericHost: "127.0.0.1", port: receiver.boundPort)!
        try sender.send(Data("LSL:shortinfo\r\n".utf8), to: destination)

        var iterator = receiver.datagrams.makeAsyncIterator()
        let datagram = await iterator.next()
        #expect(datagram?.payload == Data("LSL:shortinfo\r\n".utf8))
        #expect(datagram?.source.host == "127.0.0.1")
        #expect(datagram?.source.port == sender.boundPort)
        #expect((datagram?.receivedAt ?? 0) > 0)
    }

    @Test("Closing finishes the datagram stream")
    func closeFinishesStream() async throws {
        let endpoint = try DatagramEndpoint(family: sa_family_t(AF_INET), port: 0)
        endpoint.close()
        var count = 0
        for await _ in endpoint.datagrams { count += 1 }
        #expect(count == 0)
    }
}

@Suite("Protocol clock")
struct ClockTests {
    @Test("The clock is monotonic and in seconds")
    func monotonic() async throws {
        let first = lslClock()
        try await Task.sleep(for: .milliseconds(20))
        let second = lslClock()
        #expect(second > first)
        #expect(second - first < 1.0)
        #expect(second - first > 0.01)
    }
}
