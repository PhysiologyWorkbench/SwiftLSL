import ArgumentParser
import Darwin
import Foundation

/// Raw byte echo. Proves the harness plumbing — process lifecycle, NDJSON contract,
/// readiness events, SIGTERM teardown — with zero protocol code (ROADMAP.md step 1).
///
/// Both echo servers use BSD sockets. `NWListener` is not used here (and never in the
/// library: an inlet only ever connects out), which also sidesteps its failing to start
/// at all on this macOS build.
struct EchoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "echo",
        abstract: "Echo bytes back to a peer.",
        subcommands: [EchoTCP.self, EchoUDP.self]
    )
}

struct EchoTCP: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tcp",
        abstract: "Accept one TCP connection and echo bytes until EOF."
    )

    @Option(help: "Port to bind. 0 selects an OS-assigned port.")
    var port: UInt16 = 0

    func run() throws {
        Termination.exitOnSIGTERM()

        let listener = try BoundSocket(type: SOCK_STREAM, port: port)
        guard listen(listener.handle, 1) == 0 else { throw ToolError.errno("listen") }
        Emit.event("ready", ["proto": "tcp", "port": .int(Int(listener.port))])

        var peer = sockaddr_storage()
        var peerLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let connection = withUnsafeMutablePointer(to: &peer) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                accept(listener.handle, $0, &peerLength)
            }
        }
        guard connection >= 0 else { throw ToolError.errno("accept") }
        defer { close(connection) }

        var buffer = [UInt8](repeating: 0, count: 65536)
        var echoed = 0
        while true {
            let received = read(connection, &buffer, buffer.count)
            if received < 0 {
                if errno == EINTR { continue }
                throw ToolError.errno("read")
            }
            if received == 0 { break }
            var written = 0
            while written < received {
                let sent = buffer.withUnsafeBytes {
                    write(connection, $0.baseAddress! + written, received - written)
                }
                if sent < 0 {
                    if errno == EINTR { continue }
                    throw ToolError.errno("write")
                }
                written += sent
            }
            echoed += received
        }

        Emit.event("closed", ["proto": "tcp", "bytes": .int(echoed)])
    }
}

struct EchoUDP: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "udp",
        abstract: "Echo every received datagram back to its sender."
    )

    @Option(help: "Port to bind. 0 selects an OS-assigned port.")
    var port: UInt16 = 0

    func run() throws {
        Termination.exitOnSIGTERM()

        let endpoint = try BoundSocket(type: SOCK_DGRAM, port: port)
        Emit.event("ready", ["proto": "udp", "port": .int(Int(endpoint.port))])

        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            var peer = sockaddr_storage()
            var peerLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let received = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(endpoint.handle, &buffer, buffer.count, 0, $0, &peerLength)
                }
            }
            if received < 0 {
                if errno == EINTR { continue }
                throw ToolError.errno("recvfrom")
            }
            let sent = withUnsafePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(endpoint.handle, &buffer, received, 0, $0, peerLength)
                }
            }
            guard sent == received else { throw ToolError.errno("sendto") }
            Emit.event("echo", ["proto": "udp", "bytes": .int(received)])
        }
    }
}

/// An IPv4 socket bound to a port, with the OS-assigned port read back.
private final class BoundSocket {
    let handle: Int32
    let port: UInt16

    init(type: Int32, port requested: UInt16) throws {
        let handle = socket(AF_INET, type, 0)
        guard handle >= 0 else { throw ToolError.errno("socket") }
        self.handle = handle

        var reuse: Int32 = 1
        setsockopt(handle, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = requested.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(handle)
            throw ToolError.errno("bind")
        }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(handle, $0, &length)
            }
        }
        guard named == 0 else {
            close(handle)
            throw ToolError.errno("getsockname")
        }
        port = UInt16(bigEndian: actual.sin_port)
    }

    deinit { close(handle) }
}
