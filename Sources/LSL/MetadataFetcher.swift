import Foundation
import LSLCore

/// Fetches a stream's complete `<info>` document, `<desc>` subtree included
/// (SCOPE.md §2.4, `src/info_receiver.cpp:44-88`).
///
/// This is a separate TCP round trip on the data port, not part of the data phase: the
/// outlet writes the whole document and closes, so the reply is delimited by end of stream
/// rather than by a length.
package enum MetadataFetcher {
    static let request = Data("LSL:fullinfo\r\n".utf8)

    /// A `created_at` of 0 means the response was not a valid stream info; the reference
    /// simply reconnects and asks again, so this does too.
    package static func fetch(
        host: String,
        port: UInt16,
        timeout: Duration = .seconds(5),
        attempts: Int = 3
    ) async throws -> StreamInfo {
        var lastError: any Error = LSLError.timedOut("fetching metadata")
        for _ in 0..<max(1, attempts) {
            do {
                let info = try await fetchOnce(host: host, port: port, timeout: timeout)
                if info.createdAt != 0 { return info }
                lastError = LSLError.invalidStreamInfo("created_at is 0")
            } catch let error as LSLError {
                switch error {
                case .invalidStreamInfo, .malformedMessage, .lost:
                    lastError = error
                default:
                    throw error
                }
            }
        }
        throw lastError
    }

    private static func fetchOnce(
        host: String, port: UInt16, timeout: Duration
    ) async throws -> StreamInfo {
        let connection = try TCPConnection(host: host, port: port)
        defer { connection.close() }
        try await connection.open(timeout: timeout)
        try await connection.send(request)

        // Read to end of stream. A `<desc>` with per-channel metadata for a high-count
        // montage runs to tens of kilobytes, so this always spans several reads.
        var document = Data()
        while let chunk = try await connection.receive(), !chunk.isEmpty {
            document.append(chunk)
        }
        guard !document.isEmpty else {
            throw LSLError.invalidStreamInfo("the outlet returned an empty document")
        }
        return try StreamInfoXML.decode(document)
    }
}
