/// Pure wire-format codecs for the Lab Streaming Layer protocol.
///
/// This module imports Foundation only: every byte-level decision in SCOPE.md §2 is
/// testable here without a peer, an entitlement, or a network stack.
package enum LSLCore {
    /// Highest data-protocol version this implementation speaks (SCOPE.md §2.2).
    package static let maximumProtocolVersion = 110
}
