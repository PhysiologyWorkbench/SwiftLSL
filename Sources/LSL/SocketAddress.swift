import Darwin
import Foundation
import LSLCore

/// An IPv4 or IPv6 socket address, stored in the form the BSD socket calls want.
///
/// The textual host and the port are derived once, with `inet_ntop` rather than
/// `getnameinfo`: the latter fails outright on an unscoped link-local address such as the
/// `FF02:` discovery group, which would leave a legitimate target unnameable.
public struct SocketAddress: Sendable, Hashable {
    private var storage: sockaddr_storage
    public let length: socklen_t
    public let host: String
    public let port: UInt16

    public var family: sa_family_t { storage.ss_family }
    public var isIPv6: Bool { family == sa_family_t(AF_INET6) }
    /// The interface index carried by an IPv6 address; 0 when unscoped. A link-local
    /// address is not routable without it (SCOPE.md §8.5).
    public let scopeID: UInt32

    init(storage: sockaddr_storage, length: socklen_t) {
        self.storage = storage
        self.length = length
        var storageCopy = storage
        if storage.ss_family == sa_family_t(AF_INET6) {
            let address = withUnsafePointer(to: &storageCopy) {
                $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
            }
            scopeID = address.sin6_scope_id
            var raw = address.sin6_addr
            var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            inet_ntop(AF_INET6, &raw, &text, socklen_t(INET6_ADDRSTRLEN))
            var name = Self.string(text)
            if scopeID != 0 {
                var interface = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                if if_indextoname(scopeID, &interface) != nil {
                    name += "%" + Self.string(interface)
                }
            }
            host = name
            port = UInt16(bigEndian: address.sin6_port)
        } else {
            let address = withUnsafePointer(to: &storageCopy) {
                $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            }
            scopeID = 0
            var raw = address.sin_addr
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &raw, &text, socklen_t(INET_ADDRSTRLEN))
            host = Self.string(text)
            port = UInt16(bigEndian: address.sin_port)
        }
    }

    /// Parses a numeric address. Returns `nil` for anything needing name resolution.
    public init?(numericHost host: String, port: UInt16) {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        hints.ai_socktype = SOCK_DGRAM
        guard let first = Self.lookUp(host: host, port: port, hints: hints).first else {
            return nil
        }
        self = first
    }

    /// Resolves a host name to every address it has, in `getaddrinfo` order.
    ///
    /// On Apple platforms resolving a `.local` name is itself gated by local network
    /// access, so a `KnownPeers` entry like `rig-2.local` can fail for permission reasons
    /// alone (SCOPE.md §8.2).
    public static func resolve(host: String, port: UInt16) -> [SocketAddress] {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_DGRAM
        return lookUp(host: host, port: port, hints: hints)
    }

    private static func lookUp(host: String, port: UInt16, hints: addrinfo) -> [SocketAddress] {
        var hints = hints
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let head = result else {
            return []
        }
        defer { freeaddrinfo(head) }

        var addresses: [SocketAddress] = []
        var node: UnsafeMutablePointer<addrinfo>? = head
        while let current = node {
            if let raw = current.pointee.ai_addr {
                var storage = sockaddr_storage()
                let length = current.pointee.ai_addrlen
                _ = withUnsafeMutableBytes(of: &storage) { destination in
                    UnsafeRawBufferPointer(start: raw, count: Int(length))
                        .copyBytes(to: destination)
                }
                addresses.append(SocketAddress(storage: storage, length: length))
            }
            node = current.pointee.ai_next
        }
        return addresses
    }

    /// A copy bound to a particular interface. Only meaningful for IPv6: a link-local
    /// peer or multicast group is unreachable without a scope (SCOPE.md §8.5).
    public func withScopeID(_ scopeID: UInt32) -> SocketAddress {
        guard isIPv6 else { return self }
        var copy = storage
        withUnsafeMutablePointer(to: &copy) {
            $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                $0.pointee.sin6_scope_id = scopeID
            }
        }
        return SocketAddress(storage: copy, length: length)
    }

    func withSockaddr<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) rethrows -> T {
        try withUnsafePointer(to: storage) {
            try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, length) }
        }
    }

    private static func string(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public static func == (lhs: SocketAddress, rhs: SocketAddress) -> Bool {
        lhs.host == rhs.host && lhs.port == rhs.port && lhs.family == rhs.family
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(host)
        hasher.combine(port)
        hasher.combine(family)
    }
}
