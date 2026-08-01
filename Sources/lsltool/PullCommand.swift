import ArgumentParser
import Foundation
import LSL

/// Connects to an explicit endpoint and emits decoded samples (ROADMAP.md step 4).
///
/// The endpoint is supplied by the harness, which obtains it from pylsl, so this path is
/// testable independently of our own resolver (TESTING.md).
struct PullCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pull",
        abstract: "Open a data-phase connection and emit samples as NDJSON."
    )

    @Option(help: "Outlet host.")
    var host: String

    @Option(help: "Outlet data port.")
    var port: UInt16

    @Option(help: "Stream UID, as advertised in the discovery XML.")
    var uid: String

    @Option(help: "Channel count.")
    var channels: Int

    @Option(help: "Channel format token, e.g. float32.")
    var format: String

    @Option(help: "Nominal sample rate; 0 for an irregular stream.")
    var srate: Double = 0

    @Option(help: "Advertised protocol version × 100.")
    var protocolVersion: Int = 110

    @Option(help: "Number of samples to emit before exiting. 0 means run until SIGTERM.")
    var count: Int = 0

    @Option(help: "Seconds of data the outlet may buffer for us.")
    var maxBuffered: Double = 360

    @Flag(help: "Emit only the summary event, not each sample.")
    var quiet = false

    func run() async throws {
        Termination.exitOnSIGTERM()

        guard let channelFormat = ChannelFormat(wireName: format) else {
            throw ToolError("unknown channel format '\(format)'")
        }
        let info = StreamInfo(
            name: "pull", channelCount: channels, nominalSampleRate: srate,
            channelFormat: channelFormat, uid: uid, protocolVersion: protocolVersion)

        var settings = InletConfiguration()
        settings.maxBuffered = .seconds(maxBuffered)
        let feed = try await DataConnection.open(
            to: info, host: host, port: port, configuration: settings)
        defer { feed.close() }

        Emit.event(
            "ready",
            [
                "proto": "tcp",
                "byte_order": .int(feed.byteOrder.rawValue),
                "suppress_subnormals": .bool(feed.suppressSubnormals),
            ])

        var emitted = 0
        var first: Double?
        var last: Double = 0
        while count == 0 || emitted < count {
            let sample = try await feed.nextSample()
            emitted += 1
            if first == nil { first = sample.timestamp }
            last = sample.timestamp
            if !quiet {
                Emit.event(
                    "sample",
                    ["t": .double(sample.timestamp), "v": Self.values(sample.values)])
            }
        }

        Emit.event(
            "done",
            [
                "count": .int(emitted),
                "first_timestamp": .double(first ?? 0),
                "last_timestamp": .double(last),
            ])
    }

    static func values(_ values: SampleValues) -> JSONValue {
        switch values {
        case .float32(let v): .array(v.map { .double(Double($0)) })
        case .double64(let v): .array(v.map { .double($0) })
        case .int8(let v): .array(v.map { .int(Int($0)) })
        case .int16(let v): .array(v.map { .int(Int($0)) })
        case .int32(let v): .array(v.map { .int(Int($0)) })
        case .int64(let v): .array(v.map { .int(Int($0)) })
        case .string(let v): .array(v.map { .string($0) })
        }
    }
}
