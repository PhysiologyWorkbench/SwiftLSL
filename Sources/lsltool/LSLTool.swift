import ArgumentParser
import Darwin
import Foundation

@main
struct LSLTool: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lsltool",
        abstract: "Development harness for SwiftLSL. stdout is NDJSON; stderr is diagnostics.",
        subcommands: [
            EchoCommand.self, ResolveCommand.self, PullCommand.self, InfoCommand.self,
        ]
    )

    /// Argument-parsing failures and `--help` keep ArgumentParser's own stderr handling.
    /// Anything thrown out of a subcommand's `run()`, by contrast, is a runtime failure the
    /// harness must be able to read, so it becomes a terminal NDJSON `error` line
    /// (ARCHITECTURE.md).
    static func main() async {
        var command: any ParsableCommand
        do {
            command = try parseAsRoot()
        } catch {
            exit(withError: error)
        }

        do {
            if var asyncCommand = command as? any AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch let error as ExitCode {
            Darwin.exit(error.rawValue)
        } catch let error as ToolError {
            Emit.error(error.description)
            Darwin.exit(1)
        } catch {
            Emit.error("\(error)")
            Darwin.exit(1)
        }
    }
}
