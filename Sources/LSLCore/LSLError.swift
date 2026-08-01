/// Best-effort local-network authorisation state.
///
/// There is no system API for this (TN3179, FB8711182); it is inferred from
/// `NWConnection`, and `.unknown` is a legitimate and common answer (SCOPE.md §8.2).
public enum LocalNetworkAccess: Sendable, Hashable {
    case allowed
    case denied
    case unknown
}

/// Every error this package raises.
///
/// `lost`, `timedOut` and `refused` are deliberately distinct, mirroring `liblsl`'s
/// `lost_error`/`timeout_error` split: a recorder reacts differently to each
/// (ARCHITECTURE.md, *Error model*).
public enum LSLError: Error, Sendable, Hashable {
    /// The stream went away: the peer closed, redirected, or no longer serves this UID.
    case lost(String)
    /// An operation did not complete within its deadline.
    case timedOut(String)
    /// The transport could not be established.
    case refused(String)

    /// The outlet speaks a protocol this package deliberately does not implement.
    /// Detected before connecting from the discovery XML where possible (SCOPE.md §4).
    case unsupportedProtocolVersion(Int)
    /// A peer's message did not parse.
    case malformedMessage(String)
    /// The stream info XML was absent, unparseable, or missing a required field.
    case invalidStreamInfo(String)
    /// The two test-pattern samples did not match the ones we generated: the protocol
    /// formats are incompatible and the connection must be dropped (SCOPE.md §2.2).
    case testPatternMismatch
    /// The outlet answered with a different stream than the one requested.
    case uidMismatch(expected: String, received: String)
    /// The peer asked for a byte order this format cannot be decoded in (SCOPE.md §2.2).
    case unsupportedByteOrder(Int)
    /// The peer sent an error status line.
    case statusError(code: Int, message: String)

    /// A record is not yet complete in the buffer. Read more bytes and decode again from
    /// the same offset; never surfaces to a caller of the public API.
    case incompleteRecord

    /// No outlets replied, and the probe reports local network access is denied.
    case localNetworkDenied
    /// No outlets replied. On Apple platforms a denial is silent on UDP, so an empty
    /// resolve is ambiguous and carries the probed access state (SCOPE.md §8.2).
    case noStreamsFound(accessState: LocalNetworkAccess)
}
