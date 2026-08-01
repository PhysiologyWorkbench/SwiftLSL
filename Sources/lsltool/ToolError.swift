import Foundation

struct ToolError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }

    static func errno(_ call: String) -> ToolError {
        ToolError("\(call): \(String(cString: strerror(Darwin.errno)))")
    }
}
