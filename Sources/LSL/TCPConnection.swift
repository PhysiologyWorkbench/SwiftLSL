import Foundation
import LSLCore
import Network

/// An outbound TCP connection, the transport for the data phase and `LSL:fullinfo`.
///
/// `NWConnection` is a clean fit here: point-to-point, connection-oriented, TCP no-delay
/// via `NWProtocolTCP.Options`, and a receive call that maps onto "read at least N bytes"
/// (SCOPE.md §6). It is also the only documented source of a local-network denial signal
/// (SCOPE.md §8.2, gap #21).
final class TCPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "org.swiftlsl.tcp")

    init(host: String, port: UInt16) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw LSLError.refused("invalid port \(port)")
        }
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?
            .noDelay = true

        connection = NWConnection(
            to: .hostPort(host: Self.host(host), port: endpointPort), using: parameters)
    }

    /// An IPv6 link-local address carries its scope as a `%interface` suffix, which
    /// `IPv6Address` parses into the interface the endpoint needs; an address string alone
    /// is not routable (SCOPE.md §8.5).
    private static func host(_ text: String) -> NWEndpoint.Host {
        if let address = IPv4Address(text) { return .ipv4(address) }
        if let address = IPv6Address(text) { return .ipv6(address) }
        return .name(text, nil)
    }

    func open(timeout: Duration) async throws {
        let box = ContinuationBox<Void>()
        connection.stateUpdateHandler = { [connection] state in
            switch state {
            case .ready:
                box.resume(returning: ())
            case .waiting(let error):
                // The system retries a waiting connection by itself once the user grants
                // access, but a denial is worth surfacing straight away: it is the one
                // condition no amount of waiting fixes.
                if connection.currentPath?.unsatisfiedReason == .localNetworkDenied {
                    box.resume(throwing: LSLError.localNetworkDenied)
                } else if case .posix(let code) = error, code == .ECONNREFUSED {
                    box.resume(throwing: LSLError.refused("connection refused"))
                }
            case .failed(let error):
                box.resume(throwing: LSLError.refused("\(error)"))
            case .cancelled:
                box.resume(throwing: LSLError.lost("connection cancelled"))
            default:
                break
            }
        }
        connection.start(queue: queue)

        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            box.resume(throwing: LSLError.timedOut("connecting"))
        }
        defer { timeoutTask.cancel() }

        do {
            try await withCheckedThrowingContinuation { continuation in
                box.install(continuation)
                box.flush()
            }
        } catch {
            connection.cancel()
            throw error
        }
    }

    func send(_ payload: Data) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(
                content: payload,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: LSLError.lost("send failed: \(error)"))
                    } else {
                        continuation.resume()
                    }
                })
        }
    }

    /// Reads whatever has arrived, blocking until at least one byte is available.
    /// Returns `nil` at end of stream.
    func receive(maximumLength: Int = 65536) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) {
                data, _, isComplete, error in
                if let error, !isComplete {
                    continuation.resume(throwing: LSLError.lost("receive failed: \(error)"))
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    func close() {
        connection.stateUpdateHandler = nil
        connection.cancel()
    }
}

/// Bridges a callback that may fire any number of times onto a continuation that must be
/// resumed exactly once, tolerating a resume that arrives before the continuation does.
final class ContinuationBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var pending: Result<Value, any Error>?
    private var finished = false

    func install(_ continuation: CheckedContinuation<Value, any Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    /// Delivers a result that arrived before `install`.
    func flush() {
        lock.lock()
        guard let pending, let continuation, !finished else {
            lock.unlock()
            return
        }
        finished = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: pending)
    }

    func resume(with result: sending Result<Value, any Error>) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        guard let continuation else {
            pending = result
            lock.unlock()
            return
        }
        finished = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }

    func resume(returning value: sending Value) { resume(with: .success(value)) }
    func resume(throwing error: any Error) { resume(with: .failure(error)) }
}
