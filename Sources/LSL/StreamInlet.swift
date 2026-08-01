import Foundation
import LSLCore

/// A subscription to one stream: samples, clock offsets, and recovery when the outlet
/// goes away and comes back (SCOPE.md §7).
public actor StreamInlet {
    private nonisolated let infoStorage: Locked<StreamInfo>
    private nonisolated let configuration: InletConfiguration
    private nonisolated let resolver: StreamResolver

    private var connection: DataConnection?
    private var readerTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var synchroniserTask: Task<Void, Never>?

    private var buffer: [Sample] = []
    private var droppedSamples = 0
    private var sampleWaiters = WaiterSet()
    private var terminalError: (any Error)?
    private var closed = false

    private nonisolated let lastReceive = Locked(0.0)

    private var latestOffset: ClockOffset?
    private var offsetWaiters = WaiterSet()
    private var offsetWasReset = false
    private let offsetsContinuation: AsyncStream<ClockOffset>.Continuation

    /// Every clock-offset measurement, for recording alongside the samples (SCOPE.md §9).
    public nonisolated let clockOffsets: AsyncStream<ClockOffset>

    /// The stream this inlet is currently attached to. After a recovery it is the
    /// replacement stream's info, with a new UID and possibly a new address.
    public nonisolated var info: StreamInfo { infoStorage.withLock { $0 } }

    public init(
        _ info: StreamInfo,
        configuration: InletConfiguration = .init(),
        resolver: StreamResolver = StreamResolver()
    ) throws {
        guard info.protocolVersion >= 110 else {
            throw LSLError.unsupportedProtocolVersion(info.protocolVersion)
        }
        guard !info.v4Address.isEmpty || !info.v6Address.isEmpty else {
            throw LSLError.invalidStreamInfo("the stream info carries no address")
        }
        self.infoStorage = Locked(info)
        self.configuration = configuration
        self.resolver = resolver
        let (stream, continuation) = AsyncStream<ClockOffset>.makeStream()
        self.clockOffsets = stream
        self.offsetsContinuation = continuation
    }

    // MARK: - Lifecycle

    /// Connects, passes the test-pattern gate, and starts the reader, the watchdog and
    /// the time synchroniser.
    public func open(timeout: Duration = .seconds(5)) async throws {
        guard readerTask == nil else { return }
        let endpoint = try Self.dataEndpoint(for: info)
        let feed = try await DataConnection.open(
            to: info, host: endpoint.host, port: endpoint.port,
            configuration: configuration, timeout: timeout)
        connection = feed
        lastReceive.withLock { $0 = lslClock() }
        startReader()
        startWatchdog()
        startSynchroniser()
    }

    public func close() {
        guard !closed else { return }
        closed = true
        readerTask?.cancel()
        watchdogTask?.cancel()
        synchroniserTask?.cancel()
        connection?.close()
        connection = nil
        offsetsContinuation.finish()
        wakeSampleWaiters()
        wakeOffsetWaiters()
    }

    /// Full metadata including `<desc>`; a separate TCP round trip (SCOPE.md §2.4).
    public func fetchMetadata(timeout: Duration = .seconds(5)) async throws -> StreamInfo {
        let endpoint = try Self.dataEndpoint(for: info)
        var full = try await MetadataFetcher.fetch(
            host: endpoint.host, port: endpoint.port, timeout: timeout)
        // The document an outlet serves carries no address of its own (SCOPE.md §2.4), so
        // keep the one discovery gave us.
        full.v4Address = info.v4Address
        full.v6Address = info.v6Address
        return full
    }

    // MARK: - Samples

    /// The next sample, or `nil` if none arrives within `timeout`.
    public func pullSample(timeout: Duration = .seconds(1)) async throws -> Sample? {
        let deadline = ContinuousClock.now + timeout
        while true {
            if let sample = takeBuffered() { return sample }
            if let terminalError { throw terminalError }
            if closed { return nil }
            guard ContinuousClock.now < deadline else { return nil }
            await waitForSamples(until: deadline)
        }
    }

    /// Up to `maxSamples`, returning as soon as at least one is available.
    public func pullChunk(maxSamples: Int, timeout: Duration = .seconds(1)) async throws
        -> [Sample]
    {
        guard let first = try await pullSample(timeout: timeout) else { return [] }
        var chunk = [first]
        while chunk.count < maxSamples, let next = takeBuffered() {
            chunk.append(next)
        }
        return chunk
    }

    /// Continuous delivery. Terminates when the stream is irrecoverably lost.
    ///
    /// This draws from the same buffer as `pullSample`, so using both at once splits the
    /// stream between them — as it does in the reference implementation.
    public nonisolated var samples: AsyncThrowingStream<Sample, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    while true {
                        guard let sample = try await self.nextSample() else { break }
                        continuation.yield(sample)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Waits indefinitely for the next sample; `nil` once the inlet is closed.
    private func nextSample() async throws -> Sample? {
        while true {
            if let sample = takeBuffered() { return sample }
            if let terminalError { throw terminalError }
            if closed { return nil }
            await waitForSamples(until: nil)
        }
    }

    /// How many samples the outlet's buffer overran and this inlet had to discard.
    public func droppedSampleCount() -> Int { droppedSamples }

    // MARK: - Clock offsets

    /// The most recent offset, awaiting the first measurement if none has completed.
    public func clockOffset(timeout: Duration = .seconds(5)) async throws -> ClockOffset {
        if let latestOffset { return latestOffset }
        let deadline = ContinuousClock.now + timeout
        while latestOffset == nil, !closed, ContinuousClock.now < deadline {
            await waitForOffset(until: deadline)
        }
        guard let latestOffset else {
            throw LSLError.timedOut("waiting for a clock offset")
        }
        return latestOffset
    }

    /// True once since the last call if the offset series was discontinuous.
    ///
    /// A recorder **must** segment on this: on recovery the peer may be a different
    /// process with a different clock epoch, and fitting one line across the reset is
    /// silently wrong (SCOPE.md §9).
    public func consumeOffsetResetFlag() -> Bool {
        defer { offsetWasReset = false }
        return offsetWasReset
    }

    // MARK: - Reader, watchdog, recovery

    /// The reader is a loop of short actor-isolated steps rather than a long-lived task
    /// holding the connection: `DataConnection` is not `Sendable`, and keeping it inside
    /// the actor is what makes that true by construction.
    private func startReader() {
        readerTask = Task { [weak self] in
            while true {
                guard let inlet = self, await inlet.readStep() else { return }
            }
        }
    }

    /// Returns false when the reader should stop for good.
    private func readStep() async -> Bool {
        if closed { return false }
        guard let active = connection else { return await reconnectStep() }
        do {
            let sample = try await active.nextSample()
            deliver(sample)
            return true
        } catch {
            if closed { return false }
            active.close()
            connection = nil
            return beginRecovery(after: error)
        }
    }

    private var isClosed: Bool { closed }

    private func deliver(_ sample: Sample) {
        lastReceive.withLock { $0 = lslClock() }
        let capacity = configuration.maxBufferLength(for: info)
        buffer.append(sample)
        if buffer.count > capacity {
            droppedSamples += buffer.count - capacity
            buffer.removeFirst(buffer.count - capacity)
        }
        wakeSampleWaiters()
    }

    /// Watchdog: silence for `watchdogThreshold` means the stream has stalled without the
    /// socket noticing. Closing the connection makes the reader's next read fail, which
    /// takes it down the same recovery path a real disconnect would.
    private func startWatchdog() {
        let threshold = configuration.watchdogThreshold.seconds
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let inlet = self, await !inlet.isClosed else { return }
                if lslClock() - inlet.lastReceive.withLock({ $0 }) > threshold {
                    await inlet.stall()
                }
            }
        }
    }

    private func stall() {
        lastReceive.withLock { $0 = lslClock() }
        connection?.close()
    }

    private func beginRecovery(after error: any Error) -> Bool {
        guard configuration.recoverLostStream else {
            fail(with: error)
            return false
        }
        // Without a source id nothing identifies "the same stream": a recovery could
        // silently bind to a different device mid-recording, which is worse than
        // surfacing the loss.
        guard !info.sourceID.isEmpty else {
            fail(with: LSLError.lost("stream lost and it has no source_id to recover by"))
            return false
        }
        return true
    }

    /// One attempt at finding the stream again and reconnecting to it.
    private func reconnectStep() async -> Bool {
        do {
            let replacement = try await resolveReplacement()
            let previousUID = info.uid
            infoStorage.withLock { $0 = replacement }
            if replacement.uid != previousUID {
                // A different process may have a different clock epoch, so the offset
                // series is discontinuous here (`src/time_receiver.cpp:212-219`).
                offsetWasReset = true
                latestOffset = nil
                restartSynchroniser()
            }
            let endpoint = try Self.dataEndpoint(for: replacement)
            connection = try await DataConnection.open(
                to: replacement, host: endpoint.host, port: endpoint.port,
                configuration: configuration)
            lastReceive.withLock { $0 = lslClock() }
            return true
        } catch {
            try? await Task.sleep(for: .milliseconds(250))
            return !closed
        }
    }

    /// Re-resolves by the recovery query — which deliberately omits `nominal_srate`,
    /// because float round-tripping breaks matching (SCOPE.md gap #16).
    private func resolveReplacement() async throws -> StreamInfo {
        let query = Query.recovery(for: info)
        let found = try await resolver.resolve(query: query, minimum: 1, timeout: .seconds(2))
        if let same = found.first(where: { $0.uid == info.uid }) { return same }
        // More than one candidate means the source ids are not unique. Reconnecting to a
        // guess is worse than waiting, so retry rather than choose
        // (`src/inlet_connection.cpp:205-216`).
        guard found.count == 1, let replacement = found.first else {
            throw LSLError.lost("no unique replacement stream")
        }
        return replacement
    }

    private func fail(with error: any Error) {
        terminalError = error
        wakeSampleWaiters()
    }

    // MARK: - Time synchroniser

    private func startSynchroniser() {
        let endpoint = try? Self.serviceEndpoint(for: info)
        guard let endpoint else { return }
        synchroniserTask = Task { [weak self] in
            let synchroniser = TimeSynchroniser(host: endpoint.host, port: endpoint.port)
            let offsets = synchroniser.offsets()
            do {
                for try await offset in offsets {
                    guard let self else { return }
                    await self.publish(offset)
                }
            } catch {
                // A time-sync failure never takes the sample flow down with it; the
                // recorder simply has no offsets to write for that period.
            }
        }
    }

    private func restartSynchroniser() {
        synchroniserTask?.cancel()
        startSynchroniser()
    }

    private func publish(_ offset: ClockOffset) {
        latestOffset = offset
        offsetsContinuation.yield(offset)
        wakeOffsetWaiters()
    }

    // MARK: - Waiting

    private func takeBuffered() -> Sample? {
        buffer.isEmpty ? nil : buffer.removeFirst()
    }

    private func waitForSamples(until deadline: ContinuousClock.Instant?) async {
        let id = sampleWaiters.allocate()
        if let deadline {
            Task { [weak self] in
                try? await Task.sleep(until: deadline, clock: .continuous)
                await self?.wakeSampleWaiters()
            }
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                sampleWaiters.park(id, continuation)
            }
        } onCancel: {
            Task { [weak self] in await self?.cancelSampleWait(id) }
        }
    }

    private func cancelSampleWait(_ id: Int) {
        sampleWaiters.cancel(id)
    }

    private func wakeSampleWaiters() {
        sampleWaiters.resumeAll()
    }

    private func waitForOffset(until deadline: ContinuousClock.Instant) async {
        let id = offsetWaiters.allocate()
        Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            await self?.wakeOffsetWaiters()
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                offsetWaiters.park(id, continuation)
            }
        } onCancel: {
            Task { [weak self] in await self?.cancelOffsetWait(id) }
        }
    }

    private func cancelOffsetWait(_ id: Int) {
        offsetWaiters.cancel(id)
    }

    private func wakeOffsetWaiters() {
        offsetWaiters.resumeAll()
    }

    // MARK: - Endpoints

    static func dataEndpoint(for info: StreamInfo) throws -> (host: String, port: UInt16) {
        if !info.v4Address.isEmpty, info.v4DataPort != 0 {
            return (info.v4Address, info.v4DataPort)
        }
        if !info.v6Address.isEmpty, info.v6DataPort != 0 {
            return (info.v6Address, info.v6DataPort)
        }
        throw LSLError.invalidStreamInfo("the stream info carries no usable data endpoint")
    }

    static func serviceEndpoint(for info: StreamInfo) throws -> (host: String, port: UInt16) {
        if !info.v4Address.isEmpty, info.v4ServicePort != 0 {
            return (info.v4Address, info.v4ServicePort)
        }
        if !info.v6Address.isEmpty, info.v6ServicePort != 0 {
            return (info.v6Address, info.v6ServicePort)
        }
        throw LSLError.invalidStreamInfo("the stream info carries no usable service endpoint")
    }
}
