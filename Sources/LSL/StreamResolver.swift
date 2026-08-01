import Foundation
import LSLCore

/// Finds outlets by sending `LSL:shortinfo` queries and collecting unicast replies
/// (SCOPE.md §2.1).
public struct StreamResolver: Sendable {
    /// The scope, session and peer settings every resolve on this instance uses.
    public let configuration: ResolverConfiguration

    public init(configuration: ResolverConfiguration = .init()) {
        self.configuration = configuration
    }

    /// Runs waves until `minimum` streams have answered or the timeout expires.
    ///
    /// Never fails fast. macOS will not show the local-network alert for a process that
    /// exits immediately after a failed local-network operation (FB16131937), so a
    /// resolver that gave up on the first send failure could leave an app permanently
    /// unable to discover anything (SCOPE.md §8.3).
    public func resolve(
        query: String? = nil,
        minimum: Int? = nil,
        timeout: Duration = .seconds(2)
    ) async throws -> [StreamInfo] {
        let session = ResolveSession()
        let endpoints = try openEndpoints()
        defer { endpoints.forEach { $0.close() } }
        let queryID = DiscoveryMessage.newQueryID()

        await withTaskGroup(of: Void.self) { group in
            for endpoint in endpoints {
                group.addTask {
                    await Self.receive(on: endpoint, queryID: queryID, into: session)
                }
            }
            group.addTask {
                await self.runWaves(
                    endpoints: endpoints, query: query, queryID: queryID, fast: true)
            }
            group.addTask { await Self.stop(after: timeout, orOnceReaching: minimum, in: session) }
            await group.next()
            group.cancelAll()
        }

        return await session.snapshot()
    }

    /// Resolves on a single StreamInfo field, e.g. `resolve(property: "type", equals: "EEG")`.
    public func resolve(
        property: String,
        equals value: String,
        minimum: Int? = nil,
        timeout: Duration = .seconds(2)
    ) async throws -> [StreamInfo] {
        try await resolve(
            query: Query.property(property, equals: value), minimum: minimum, timeout: timeout)
    }

    /// Resolves, and treats finding nothing as a failure worth diagnosing.
    ///
    /// A silent local-network denial produces exactly the same empty list as "no such
    /// stream exists" — on a raw UDP socket a denial has no signal at all (SCOPE.md §8.2).
    /// So the probe runs before the failure is reported and its answer travels in the
    /// error. `resolve` itself keeps the reference semantics: fewer results than `minimum`
    /// is not an error there (`include/lsl_cpp.h:868-871`).
    public func resolveFirst(
        query: String? = nil,
        timeout: Duration = .seconds(2)
    ) async throws -> StreamInfo {
        let found = try await resolve(query: query, minimum: 1, timeout: timeout)
        guard let first = found.first else {
            throw LSLError.noStreamsFound(accessState: await LocalNetwork.probe())
        }
        return first
    }

    /// A long-lived resolver that yields the current set on every change, including when a
    /// stream stops answering for `forgetAfter` and is forgotten.
    public func continuousResolve(
        query: String? = nil,
        forgetAfter: Duration = .seconds(5)
    ) -> AsyncStream<[StreamInfo]> {
        AsyncStream { continuation in
            let task = Task {
                guard let endpoints = try? self.openEndpoints() else {
                    continuation.finish()
                    return
                }
                defer { endpoints.forEach { $0.close() } }
                let session = ResolveSession(forgetAfter: forgetAfter)
                let queryID = DiscoveryMessage.newQueryID()

                await withTaskGroup(of: Void.self) { group in
                    for endpoint in endpoints {
                        group.addTask {
                            await Self.receive(on: endpoint, queryID: queryID, into: session)
                        }
                    }
                    group.addTask {
                        await self.runWaves(
                            endpoints: endpoints, query: query, queryID: queryID, fast: false)
                    }
                    group.addTask { await session.expirePeriodically() }
                    group.addTask {
                        for await snapshot in await session.changes() {
                            continuation.yield(snapshot)
                        }
                    }
                    await group.next()
                    group.cancelAll()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Wave scheduling

    /// Multicast burst, then — if any known peers are configured — a unicast burst after
    /// `MulticastMinRTT`, then the next wave (`src/resolver_impl.cpp:172-194`).
    ///
    /// The query id stays fixed for the whole resolve, as it does in the reference, where
    /// it is a hash of the query string and so identical in every wave
    /// (`src/resolve_attempt_udp.cpp:51`).
    private func runWaves(
        endpoints: [DatagramEndpoint], query: String?, queryID: String, fast: Bool
    ) async {
        let fullQuery = Query.session(configuration.sessionID, and: query)
        let multicast = configuration.multicastTargets()
        let unicast = configuration.unicastTargets()

        while !Task.isCancelled {
            for endpoint in endpoints {
                endpoint.setMulticastTTL(configuration.scope.ttl)
                let interfaces = NetworkInterfaces.forDiscovery(family: endpoint.family)
                guard !interfaces.isEmpty else {
                    // No enumerable interface: let the routing table pick, as the reference
                    // does with its dummy entry (`src/api_config.cpp:281-292`).
                    send(query: fullQuery, queryID: queryID, from: endpoint, to: multicast)
                    continue
                }
                for interface in interfaces {
                    endpoint.setMulticastInterface(interface)
                    send(
                        query: fullQuery, queryID: queryID, from: endpoint,
                        to: targets(multicast, via: interface))
                }
                endpoint.setMulticastInterface(nil)
            }

            var waveInterval: Duration =
                (fast ? .zero : configuration.continuousResolveInterval)
                + configuration.multicastMinRTT

            if !unicast.isEmpty {
                try? await Task.sleep(for: configuration.multicastMinRTT)
                guard !Task.isCancelled else { return }
                for endpoint in endpoints {
                    send(query: fullQuery, queryID: queryID, from: endpoint, to: unicast)
                }
                waveInterval += configuration.unicastMinRTT - configuration.multicastMinRTT
            }

            try? await Task.sleep(for: waveInterval)
        }
    }

    /// The configured targets as seen from one interface.
    ///
    /// A multicast group is scoped to the interface it leaves by, which is what makes the
    /// link-local `FF02:` group routable at all. The directed broadcast is added because
    /// `IP_MULTICAST_IF` does not steer a broadcast: `255.255.255.255` follows the default
    /// route whichever interface is selected, so on a multi-homed host it reaches exactly
    /// one network (SCOPE.md §8.5).
    func targets(_ addresses: [SocketAddress], via interface: NetworkInterface)
        -> [SocketAddress]
    {
        var targets = addresses.map { $0.isIPv6 ? $0.withScopeID(interface.index) : $0 }
        if let broadcast = interface.broadcastAddress,
            let directed = SocketAddress(
                numericHost: broadcast.host, port: configuration.multicastPort)
        {
            targets.append(directed)
        }
        return targets
    }

    /// A send failure is never fatal: an interface may be down, a scope unroutable, or the
    /// address family unsupported on this host. The wave carries on regardless.
    private func send(
        query: String, queryID: String, from endpoint: DatagramEndpoint, to targets: [SocketAddress]
    ) {
        let message = DiscoveryMessage.query(
            query, returnPort: endpoint.boundPort, queryID: queryID)
        let wantsIPv6 = endpoint.family == sa_family_t(AF_INET6)
        for target in targets where target.isIPv6 == wantsIPv6 {
            try? endpoint.send(message, to: target)
        }
    }

    private func openEndpoints() throws -> [DatagramEndpoint] {
        var endpoints: [DatagramEndpoint] = []
        if configuration.allowIPv4 {
            endpoints.append(
                try DatagramEndpoint(
                    family: sa_family_t(AF_INET), basePort: configuration.basePort,
                    portRange: configuration.portRange))
        }
        if configuration.allowIPv6 {
            // A host without an IPv6 stack must still be able to resolve over IPv4.
            if let endpoint = try? DatagramEndpoint(
                family: sa_family_t(AF_INET6), basePort: configuration.basePort,
                portRange: configuration.portRange)
            {
                endpoints.append(endpoint)
            }
        }
        guard !endpoints.isEmpty else {
            throw LSLError.refused("no usable UDP endpoint could be bound")
        }
        return endpoints
    }

    // MARK: - Receiving

    private static func receive(
        on endpoint: DatagramEndpoint, queryID: String, into session: ResolveSession
    ) async {
        for await datagram in endpoint.datagrams {
            guard let (echoed, xml) = try? DiscoveryMessage.parseReply(datagram.payload),
                echoed == queryID,
                // Malformed XML from one outlet must not disturb the wave.
                let info = try? StreamInfoXML.decode(xml)
            else { continue }
            await session.record(info, from: datagram.source)
        }
    }

    private static func stop(
        after timeout: Duration, orOnceReaching minimum: Int?, in session: ResolveSession
    ) async {
        guard let minimum, minimum > 0 else {
            try? await Task.sleep(for: timeout)
            return
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { try? await Task.sleep(for: timeout) }
            group.addTask { await session.waitForCount(minimum) }
            await group.next()
            group.cancelAll()
        }
    }
}

/// The streams one resolve has heard from.
actor ResolveSession {
    private struct Entry {
        var info: StreamInfo
        var lastSeen: Double
    }

    private var entries: [String: Entry] = [:]
    private var waiters = WaiterSet()
    private var listeners: [AsyncStream<[StreamInfo]>.Continuation] = []
    private let forgetAfter: Duration?

    init(forgetAfter: Duration? = nil) {
        self.forgetAfter = forgetAfter
    }

    func record(_ info: StreamInfo, from source: SocketAddress) {
        let isNew = entries[info.uid] == nil
        var entry = entries[info.uid] ?? Entry(info: info, lastSeen: 0)
        entry.lastSeen = lslClock()
        // The first responder's address wins — it is assumed to be the faster route — so
        // an address already recorded for this family is never overwritten
        // (`src/resolve_attempt_udp.cpp:121-141`).
        if source.isIPv6 {
            if entry.info.v6Address.isEmpty { entry.info.v6Address = source.host }
        } else {
            if entry.info.v4Address.isEmpty { entry.info.v4Address = source.host }
        }
        entries[info.uid] = entry
        if isNew { publish() }
    }

    func snapshot() -> [StreamInfo] {
        entries.values.map(\.info).sorted { $0.uid < $1.uid }
    }

    func waitForCount(_ threshold: Int) async {
        while entries.count < threshold, !Task.isCancelled {
            let id = waiters.allocate()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    waiters.park(id, continuation, satisfied: entries.count >= threshold)
                }
            } onCancel: {
                Task { await self.cancelWait(id) }
            }
        }
    }

    private func cancelWait(_ id: Int) {
        waiters.cancel(id)
    }

    func changes() -> AsyncStream<[StreamInfo]> {
        let (stream, continuation) = AsyncStream<[StreamInfo]>.makeStream()
        listeners.append(continuation)
        continuation.yield(snapshot())
        return stream
    }

    /// Drops streams that have stopped answering (`src/resolver_impl.cpp:155-165`).
    func expirePeriodically() async {
        guard let forgetAfter else { return }
        let seconds = forgetAfter.seconds
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            let cutoff = lslClock() - seconds
            let before = entries.count
            entries = entries.filter { $0.value.lastSeen >= cutoff }
            if entries.count != before { publish() }
        }
    }

    private func publish() {
        let current = snapshot()
        for listener in listeners { listener.yield(current) }
        waiters.resumeAll()
    }
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
