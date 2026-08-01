import Darwin
import Dispatch
import Foundation
import LSLCore

/// A received datagram and where it came from.
public struct Datagram: Sendable {
    public let payload: Data
    public let source: SocketAddress
    /// Our clock when the datagram was read — the `t3` of a time-sync probe (SCOPE.md §2.5).
    public let receivedAt: Double
}

/// The one BSD-socket wrapper in this package.
///
/// Both UDP legs need a socket that *sends to many addresses* and *receives from arbitrary
/// unknown sources*, with the return port known before the first send;
/// `NWConnection` is connection-scoped and `NWConnectionGroup` has no broadcast path
/// (SCOPE.md §6). The single `DispatchSourceRead` is bridged to an `AsyncStream` here and
/// does not leak outwards.
///
/// This buys nothing on the privacy front: TN3179 confirms the local-network and multicast
/// checks live below the API layer and apply to BSD sockets equally (SCOPE.md gap #20).
public final class DatagramEndpoint: @unchecked Sendable {
    /// Ports an inlet prefers, before falling back to an OS-assigned one
    /// (`src/socket_utils.cpp:5-25`).
    public static let defaultBasePort: UInt16 = 16572
    public static let defaultPortRange: UInt16 = 32

    private let handle: Int32
    private let source: DispatchSourceRead
    private let continuation: AsyncStream<Datagram>.Continuation
    private let lock = NSLock()
    private var closed = false

    public let boundPort: UInt16
    public let family: sa_family_t

    /// Every datagram received, in arrival order. Finishes when the endpoint closes.
    public let datagrams: AsyncStream<Datagram>

    /// Binds a socket, preferring `basePort ..< basePort + portRange` and falling back to
    /// an OS-assigned port. An inlet has no port-range requirement: the port it listens on
    /// travels in the query itself (SCOPE.md gap #17).
    public init(
        family: sa_family_t = sa_family_t(AF_INET),
        port: UInt16? = nil,
        basePort: UInt16 = DatagramEndpoint.defaultBasePort,
        portRange: UInt16 = DatagramEndpoint.defaultPortRange
    ) throws {
        let handle = socket(Int32(family), SOCK_DGRAM, 0)
        guard handle >= 0 else { throw LSLError.refused(Self.errnoMessage("socket")) }
        self.handle = handle
        self.family = family

        // No SO_REUSEADDR: the port search must see an occupied port as occupied. With it,
        // a wildcard bind succeeds over another process's specific bind of the same port,
        // and that process then receives the replies meant for us.
        var enabled: Int32 = 1
        setsockopt(handle, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout<Int32>.size))
        if family == sa_family_t(AF_INET6) {
            // Keep the two stacks separate: an IPv4-mapped socket would receive replies
            // whose source address cannot be handed back to `connect` unchanged.
            setsockopt(
                handle, Int32(IPPROTO_IPV6), IPV6_V6ONLY, &enabled,
                socklen_t(MemoryLayout<Int32>.size))
        }

        var boundPort: UInt16 = 0
        if let port {
            try Self.bind(handle, family: family, port: port)
            boundPort = port == 0 ? Self.localPort(handle) : port
        } else {
            var bound = false
            for candidate in basePort..<(basePort &+ portRange) {
                if (try? Self.bind(handle, family: family, port: candidate)) != nil {
                    boundPort = candidate
                    bound = true
                    break
                }
            }
            if !bound {
                try Self.bind(handle, family: family, port: 0)
                boundPort = Self.localPort(handle)
            }
        }
        self.boundPort = boundPort

        var stream: AsyncStream<Datagram>!
        var continuation: AsyncStream<Datagram>.Continuation!
        stream = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        self.datagrams = stream
        self.continuation = continuation

        source = DispatchSource.makeReadSource(fileDescriptor: handle, queue: .global())
        source.setEventHandler { [continuation] in
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                var peer = sockaddr_storage()
                var peerLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let received = withUnsafeMutablePointer(to: &peer) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(handle, &buffer, buffer.count, 0, $0, &peerLength)
                    }
                }
                guard received >= 0 else { return }
                continuation!.yield(
                    Datagram(
                        payload: Data(buffer[0..<received]),
                        source: SocketAddress(storage: peer, length: peerLength),
                        receivedAt: lslClock()
                    ))
            }
        }
        // The handler drains the socket in a loop, so it must not block on the last read.
        _ = fcntl(handle, F_SETFL, fcntl(handle, F_GETFL, 0) | O_NONBLOCK)
        source.resume()
    }

    deinit {
        close()
    }

    public func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()
        source.cancel()
        continuation.finish()
        _ = Darwin.close(handle)
    }

    public func send(_ payload: Data, to destination: SocketAddress) throws {
        let sent = payload.withUnsafeBytes { bytes in
            destination.withSockaddr { address, length in
                sendto(handle, bytes.baseAddress, bytes.count, 0, address, length)
            }
        }
        guard sent == payload.count else {
            throw LSLError.refused(Self.errnoMessage("sendto \(destination.host)"))
        }
    }

    /// Sets the multicast hop limit for subsequent sends (SCOPE.md §2.1's TTL column).
    public func setMulticastTTL(_ ttl: Int) {
        var value = Int32(ttl)
        if family == sa_family_t(AF_INET6) {
            setsockopt(
                handle, Int32(IPPROTO_IPV6), IPV6_MULTICAST_HOPS, &value,
                socklen_t(MemoryLayout<Int32>.size))
        } else {
            var byte = UInt8(clamping: ttl)
            setsockopt(
                handle, Int32(IPPROTO_IP), IP_MULTICAST_TTL, &byte,
                socklen_t(MemoryLayout<UInt8>.size))
        }
    }

    // MARK: - Binding

    private static func bind(_ handle: Int32, family: sa_family_t, port: UInt16) throws {
        var result: Int32
        if family == sa_family_t(AF_INET6) {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = family
            address.sin6_port = port.bigEndian
            address.sin6_addr = in6addr_any
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(handle, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = family
            address.sin_port = port.bigEndian
            address.sin_addr = in_addr(s_addr: INADDR_ANY)
            result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard result == 0 else { throw LSLError.refused(errnoMessage("bind \(port)")) }
    }

    private static func localPort(_ handle: Int32) -> UInt16 {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let named = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(handle, $0, &length)
            }
        }
        guard named == 0 else { return 0 }
        return SocketAddress(storage: storage, length: length).port
    }

    private static func errnoMessage(_ call: String) -> String {
        "\(call): \(String(cString: strerror(errno)))"
    }
}
