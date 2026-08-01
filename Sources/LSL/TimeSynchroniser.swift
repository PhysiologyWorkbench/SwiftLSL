import Foundation
import LSLCore

/// One clock-offset measurement, kept alongside the samples for offline alignment
/// (SCOPE.md §9).
public struct ClockOffset: Sendable, Hashable {
    /// Our clock at the midpoint of the winning probe's round trip.
    public let localTime: Double
    /// The outlet's clock at the midpoint of the same exchange.
    public let remoteTime: Double
    /// Add this to a remote timestamp to map it into the local clock.
    ///
    /// It is the *negation* of the measured offset, matching
    /// `timeoffset_ = -best_offset` (`src/time_receiver.cpp:205`). No prose source states
    /// this, and getting it backwards produces plausible-looking, doubly wrong alignment
    /// (SCOPE.md gap #8).
    public let correction: Double
    /// The winning probe's round-trip time — the only per-measurement quality signal
    /// there is, and what offline fitting should weight by (SCOPE.md §9).
    public let uncertainty: Double
}

/// Measures the offset between our clock and an outlet's, by probe waves over UDP
/// (SCOPE.md §2.5).
public struct TimeSynchroniser: Sendable {
    public struct Configuration: Sendable {
        /// `tuning.TimeProbeCount` (`src/api_config.cpp:316`).
        public var probeCount = 8
        /// `tuning.TimeProbeInterval`.
        public var probeInterval: Duration = .milliseconds(64)
        /// `tuning.TimeProbeMaxRTT`; a wave is aggregated
        /// `probeMaxRTT + probeInterval × probeCount` after it starts — 0.64 s by default.
        public var probeMaxRTT: Duration = .milliseconds(128)
        /// `tuning.TimeUpdateMinProbes`. Fewer replies than this and nothing is published.
        public var minimumProbes = 6
        /// `tuning.TimeUpdateInterval` — how often a wave starts.
        public var updateInterval: Duration = .seconds(2)

        public init() {}

        var aggregationDelay: Duration {
            probeMaxRTT + probeInterval * probeCount
        }
    }

    public let host: String
    public let port: UInt16
    public let configuration: Configuration

    public init(host: String, port: UInt16, configuration: Configuration = .init()) {
        self.host = host
        self.port = port
        self.configuration = configuration
    }

    /// Runs probe waves, yielding one offset per wave that gathered enough replies.
    /// Runs until cancelled unless `waves` is given.
    public func offsets(waves: Int? = nil) -> AsyncThrowingStream<ClockOffset, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(waves: waves, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        waves: Int?, continuation: AsyncThrowingStream<ClockOffset, any Error>.Continuation
    ) async throws {
        guard let destination = SocketAddress(numericHost: host, port: port)
            ?? SocketAddress.resolve(host: host, port: port).first
        else {
            throw LSLError.refused("cannot resolve \(host)")
        }
        let endpoint = try DatagramEndpoint(family: destination.family, port: 0)
        defer { endpoint.close() }

        let collector = WaveCollector()
        let receiver = Task {
            for await datagram in endpoint.datagrams {
                await collector.accept(datagram)
            }
        }
        defer { receiver.cancel() }

        var completed = 0
        while !Task.isCancelled, waves.map({ completed < $0 }) ?? true {
            let waveID = Int32.random(in: 1...Int32.max)
            await collector.begin(waveID: waveID)

            for probe in 0..<configuration.probeCount {
                if probe > 0 {
                    try await Task.sleep(for: configuration.probeInterval)
                }
                try? endpoint.send(
                    TimeSyncMessage.probe(waveID: waveID, t0: lslClock()), to: destination)
            }

            try await Task.sleep(for: configuration.probeMaxRTT)
            if let offset = await collector.best(minimumProbes: configuration.minimumProbes) {
                continuation.yield(offset)
            }
            completed += 1

            guard waves.map({ completed < $0 }) ?? true else { break }
            let elapsed = configuration.aggregationDelay
            if configuration.updateInterval > elapsed {
                try await Task.sleep(for: configuration.updateInterval - elapsed)
            }
        }
    }
}

/// The replies to the wave currently in flight.
private actor WaveCollector {
    private struct Estimate {
        let rtt: Double
        let offset: Double
        let localTime: Double
        let remoteTime: Double
    }

    private var waveID: Int32?
    private var estimates: [Estimate] = []

    func begin(waveID: Int32) {
        self.waveID = waveID
        estimates.removeAll(keepingCapacity: true)
    }

    /// A reply carrying any other wave id is a straggler from an earlier wave and is
    /// discarded — which is the whole point of the id (SCOPE.md §2.5).
    func accept(_ datagram: Datagram) {
        guard let reply = try? TimeSyncMessage.parseReply(datagram.payload),
            reply.waveID == waveID
        else { return }
        let (rtt, offset) = TimeSyncMessage.measure(reply, t3: datagram.receivedAt)
        estimates.append(
            Estimate(
                rtt: rtt, offset: offset,
                localTime: (datagram.receivedAt + reply.t0) / 2,
                remoteTime: (reply.t2 + reply.t1) / 2))
    }

    /// The estimate with the lowest round-trip time wins, as in NTP's clock filter
    /// (`src/time_receiver.cpp:187-210`).
    func best(minimumProbes: Int) -> ClockOffset? {
        guard estimates.count >= minimumProbes,
            let winner = estimates.min(by: { $0.rtt < $1.rtt })
        else { return nil }
        return ClockOffset(
            localTime: winner.localTime,
            remoteTime: winner.remoteTime,
            correction: -winner.offset,
            uncertainty: winner.rtt)
    }
}
