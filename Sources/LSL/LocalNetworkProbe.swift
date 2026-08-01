import Foundation
import LSLCore
import Network

/// The local-network authorisation oracle.
///
/// There is no API for the privilege's state (TN3179, FB8711182). The only documented
/// signal is an `NWConnection` that enters `.waiting` while its path reports
/// `unsatisfiedReason == .localNetworkDenied`, so the probe exists purely to create a
/// connection whose state can be read (SCOPE.md §6, §8.2).
///
/// It is also the right moment to raise the system alert: TN3179 notes that connecting a
/// UDP socket to a local network address "triggers the local network alert without
/// generating any network traffic". Call it during onboarding, in the foreground — a
/// local-network operation performed by a backgrounded iOS app with the privilege
/// undetermined is denied silently and the decision is not even recorded (SCOPE.md §8.2).
public enum LocalNetwork {
    /// The IPv4 all-hosts group. A local network address by definition, and the one this
    /// package's discovery already sends to.
    static let probeEndpoint = NWEndpoint.hostPort(host: "224.0.0.1", port: 16571)

    /// Raises the prompt if the privilege is undetermined, and infers the current state.
    ///
    /// `.unknown` is a legitimate and common answer, not an error: on macOS below 15 there
    /// is no privilege to report, and a connection that neither becomes ready nor reports
    /// a reason within the timeout is genuinely undiagnosed.
    public static func probe(timeout: Duration = .seconds(2)) async -> LocalNetworkAccess {
        let connection = NWConnection(to: probeEndpoint, using: .udp)
        defer { connection.cancel() }

        let box = ContinuationBox<LocalNetworkAccess>()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                box.resume(with: .success(.allowed))
            case .waiting:
                // A waiting connection is retried by the system on its own once the user
                // grants access, so only an explicit denial is conclusive here.
                if connection.currentPath?.unsatisfiedReason == .localNetworkDenied {
                    box.resume(with: .success(.denied))
                }
            case .failed, .cancelled:
                box.resume(with: .success(.unknown))
            default:
                break
            }
        }
        connection.start(queue: .global())

        let deadline = Task {
            try? await Task.sleep(for: timeout)
            box.resume(with: .success(.unknown))
        }
        defer { deadline.cancel() }

        let state = try? await withCheckedThrowingContinuation { continuation in
            box.install(continuation)
            box.flush()
        }
        return state ?? .unknown
    }
}
