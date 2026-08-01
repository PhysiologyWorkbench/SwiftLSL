import Dispatch
import Foundation

/// Retains the signal source for the lifetime of the process; a released
/// `DispatchSourceSignal` stops delivering.
nonisolated(unsafe) private var terminationSource: DispatchSourceSignal?

enum Termination {
    /// Installs a clean SIGTERM shutdown. The harness always terminates spawned tools
    /// this way and asserts exit status 0 (ARCHITECTURE.md).
    static func onSIGTERM(_ handler: @escaping @Sendable () -> Void) {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        source.setEventHandler(handler: handler)
        source.resume()
        terminationSource = source
    }

    /// The common case: announce and exit successfully.
    static func exitOnSIGTERM() {
        onSIGTERM {
            Emit.event("terminated")
            exit(0)
        }
    }
}
