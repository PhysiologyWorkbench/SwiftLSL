import ArgumentParser
import Foundation
import LSL

/// Runs probe waves and emits each published offset (ROADMAP.md step 6).
struct TimesyncCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "timesync",
        abstract: "Measure the clock offset to an outlet's service port."
    )

    @Option(help: "Outlet host.")
    var host: String

    @Option(help: "Outlet service port.")
    var port: UInt16

    @Option(help: "Number of probe waves to run. 0 means run until SIGTERM.")
    var waves: Int = 1

    @Option(help: "Probes per wave.")
    var probes: Int = 8

    @Option(help: "Replies needed before a wave publishes an offset.")
    var minimumProbes: Int = 6

    @Option(help: "Seconds between the start of one wave and the next.")
    var updateInterval: Double = 2

    func run() async throws {
        Termination.exitOnSIGTERM()

        var settings = TimeSynchroniser.Configuration()
        settings.probeCount = probes
        settings.minimumProbes = minimumProbes
        settings.updateInterval = .seconds(updateInterval)

        let synchroniser = TimeSynchroniser(host: host, port: port, configuration: settings)
        Emit.event("ready", ["proto": "udp", "waves": .int(waves)])

        var published = 0
        for try await offset in synchroniser.offsets(waves: waves == 0 ? nil : waves) {
            published += 1
            Emit.event(
                "offset",
                [
                    "local_time": .double(offset.localTime),
                    "remote_time": .double(offset.remoteTime),
                    "correction": .double(offset.correction),
                    "uncertainty": .double(offset.uncertainty),
                ])
        }
        Emit.event("done", ["published": .int(published)])
    }
}
