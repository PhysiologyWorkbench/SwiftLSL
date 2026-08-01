import Foundation

/// The NDJSON event stream on stdout, and human diagnostics on stderr.
///
/// stdout carries exactly one JSON object per line and nothing else; the Python harness
/// parses it (ARCHITECTURE.md). Writes go straight to the file descriptor so that a
/// pipe-connected harness sees each event as it happens, without libc buffering.
enum Emit {
    private static let lock = NSLock()
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    static func event(_ name: String, _ fields: [String: JSONValue] = [:]) {
        var object = fields
        object["event"] = .string(name)
        var line = try! encoder.encode(JSONValue.object(object))
        line.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardOutput.write(line)
    }

    static func diagnostic(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// Emits a terminal `error` event. Callers exit non-zero immediately afterwards.
    static func error(_ message: String, _ fields: [String: JSONValue] = [:]) {
        var object = fields
        object["message"] = .string(message)
        event("error", object)
    }
}
