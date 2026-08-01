import Foundation

/// Channel values of one sample, one case per `ChannelFormat`.
public enum SampleValues: Sendable, Hashable {
    case float32([Float])
    case double64([Double])
    case int8([Int8])
    case int16([Int16])
    case int32([Int32])
    case int64([Int64])
    case string([String])

    /// The number of channels carried, whatever the case.
    public var count: Int {
        switch self {
        case .float32(let v): v.count
        case .double64(let v): v.count
        case .int8(let v): v.count
        case .int16(let v): v.count
        case .int32(let v): v.count
        case .int64(let v): v.count
        case .string(let v): v.count
        }
    }

    /// The channel format this case corresponds to.
    public var format: ChannelFormat {
        switch self {
        case .float32: .float32
        case .double64: .double64
        case .int8: .int8
        case .int16: .int16
        case .int32: .int32
        case .int64: .int64
        case .string: .string
        }
    }
}

/// One sample with its timestamp resolved into the outlet's clock domain.
public struct Sample: Sendable, Hashable {
    /// Raw, as received — never clock-corrected (SCOPE.md §9).
    public let timestamp: Double
    public let values: SampleValues

    public init(timestamp: Double, values: SampleValues) {
        self.timestamp = timestamp
        self.values = values
    }
}

/// One sample record straight off the wire, before the deduced timestamp is materialised.
public struct SampleRecord: Sendable, Hashable {
    /// `nil` when the record carried tag 1, "deduce the timestamp" (SCOPE.md §2.3).
    public let timestamp: Double?
    public let values: SampleValues

    public init(timestamp: Double?, values: SampleValues) {
        self.timestamp = timestamp
        self.values = values
    }
}

/// Materialises deduced timestamps.
///
/// `t = lastTimestamp + (srate > 0 ? 1/srate : 0)`, seeded with 0 — for an irregular-rate
/// stream the previous timestamp is repeated verbatim
/// (SCOPE.md §2.3, `src/data_receiver.cpp:320-325`).
public struct TimestampDeducer: Sendable {
    public let nominalSampleRate: Double
    private var lastTimestamp: Double = 0

    public init(nominalSampleRate: Double) {
        self.nominalSampleRate = nominalSampleRate
    }

    /// Returns the record as a `Sample`, deducing the timestamp when it carried none.
    /// Stateful: records must be passed in the order they arrived.
    public mutating func materialise(_ record: SampleRecord) -> Sample {
        let timestamp: Double
        if let transmitted = record.timestamp {
            timestamp = transmitted
        } else {
            timestamp = lastTimestamp + (nominalSampleRate > 0 ? 1 / nominalSampleRate : 0)
        }
        lastTimestamp = timestamp
        return Sample(timestamp: timestamp, values: record.values)
    }
}
