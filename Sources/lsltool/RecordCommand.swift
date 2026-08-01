import ArgumentParser
import Foundation
import LSL

/// The full inlet lifecycle: resolve, then pull samples and offsets with recovery
/// (ROADMAP.md step 7).
struct RecordCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Resolve a stream and record its samples and clock offsets."
    )

    @Option(help: "XPath predicate identifying the stream, e.g. \"name='EEG'\".")
    var query: String?

    @Option(help: "Seconds to keep recording. 0 means run until SIGTERM.")
    var duration: Double = 0

    @Option(help: "Stop after this many samples. 0 means no limit.")
    var count: Int = 0

    @Option(help: "Seconds to spend resolving before giving up.")
    var resolveTimeout: Double = 5

    @Option(help: "Seconds of silence before the watchdog forces a re-resolve.")
    var watchdog: Double = 15

    @Option(name: .customLong("known-peer"), help: "Query this host by unicast. Repeatable.")
    var knownPeers: [String] = []

    @Flag(help: "Do not send to any multicast or broadcast address.")
    var noMulticast = false

    @Flag(help: "Do not attempt recovery when the stream is lost.")
    var noRecovery = false

    @Flag(help: "Emit only summary events, not each sample.")
    var quiet = false

    func run() async throws {
        Termination.exitOnSIGTERM()

        var resolverSettings = ResolverConfiguration()
        resolverSettings.knownPeers = knownPeers
        resolverSettings.useMulticast = !noMulticast
        let resolver = StreamResolver(configuration: resolverSettings)
        Emit.event("resolving", ["query": .string(query ?? "")])

        let target: StreamInfo
        do {
            target = try await resolver.resolveFirst(
                query: query, timeout: .seconds(resolveTimeout))
        } catch LSLError.noStreamsFound(let access) {
            // An empty resolve is ambiguous on Apple platforms, so the probed access state
            // travels with the failure rather than being left to the reader (SCOPE.md §8.2).
            Emit.error(
                "no stream matched \(query ?? "any query")",
                ["local_network_access": .string(String(describing: access))])
            throw ExitCode(1)
        }

        var inletSettings = InletConfiguration()
        inletSettings.watchdogThreshold = .seconds(watchdog)
        inletSettings.recoverLostStream = !noRecovery

        let inlet = try StreamInlet(target, configuration: inletSettings, resolver: resolver)
        try await inlet.open()
        Emit.event("ready", ["proto": "tcp", "uid": .string(target.uid)] )

        let offsetTask = Task {
            for await offset in inlet.clockOffsets {
                Emit.event(
                    "offset",
                    [
                        "local_time": .double(offset.localTime),
                        "remote_time": .double(offset.remoteTime),
                        "correction": .double(offset.correction),
                        "uncertainty": .double(offset.uncertainty),
                    ])
            }
        }
        defer { offsetTask.cancel() }

        let deadline = duration > 0 ? ContinuousClock.now + .seconds(duration) : nil
        var received = 0
        var lastUID = target.uid

        while true {
            if let deadline, ContinuousClock.now >= deadline { break }
            if count > 0, received >= count { break }

            guard let sample = try await inlet.pullSample(timeout: .milliseconds(500)) else {
                if let deadline, ContinuousClock.now >= deadline { break }
                continue
            }
            received += 1
            if !quiet {
                Emit.event(
                    "sample",
                    ["t": .double(sample.timestamp), "v": PullCommand.values(sample.values)])
            }
            // A reset means the offset series is discontinuous and the recorder must
            // segment here (SCOPE.md §9).
            if await inlet.consumeOffsetResetFlag() {
                let current = inlet.info
                Emit.event(
                    "reset",
                    [
                        "previous_uid": .string(lastUID),
                        "uid": .string(current.uid),
                        "sample_index": .int(received),
                    ])
                lastUID = current.uid
            }
        }

        let dropped = await inlet.droppedSampleCount()
        await inlet.close()
        Emit.event("done", ["count": .int(received), "dropped": .int(dropped)])
    }
}
