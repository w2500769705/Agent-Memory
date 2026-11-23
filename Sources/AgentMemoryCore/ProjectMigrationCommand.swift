import Foundation

public enum ProjectMigrationCommand {
    public static let flag = "--migrate-project"

    public static func run(arguments: [String], socket: URL = MemoryPaths.socket) throws -> Data {
        let usage = "用法：agent-memory-mcp \(flag) --from <源绝对路径> --to <目标绝对路径> [--dry-run]"
        var remaining = arguments.makeIterator()
        var from: String?
        var to: String?
        var dryRun = false
        while let option = remaining.next() {
            switch option {
            case "--from" where from == nil:
                from = remaining.next()
            case "--to" where to == nil:
                to = remaining.next()
            case "--dry-run" where !dryRun:
                dryRun = true
            default:
                throw MemoryError.invalid(usage)
            }
        }
        guard let from, let to else { throw MemoryError.invalid(usage) }
        let request = try Wire.data(Request(arguments: .init(from: from, to: to, dryRun: dryRun)))
        let response = try LocalConnection.call(request, socket: socket)
        if let failure = try? Wire.decode(Failure.self, response) {
            throw MemoryError.invalid(failure.toolError)
        }
        if dryRun {
            _ = try Wire.decode(ProjectMigrationPreview.self, response)
        } else {
            _ = try Wire.decode(ProjectMigrationResult.self, response)
        }
        return response
    }

    public static func shellCommand(from: String, to: String, executable: String = "agent-memory-mcp",
                                    socket: URL = MemoryPaths.socket) -> String {
        let socketPrefix = socket.path == MemoryPaths.socket.path
            ? "" : "AGENT_MEMORY_SOCKET=\(CodexSetup.shellQuote(socket.path)) "
        return socketPrefix + "\(CodexSetup.shellQuote(executable)) \(flag) " +
            "--from \(CodexSetup.shellQuote(from)) --to \(CodexSetup.shellQuote(to))"
    }

    private struct Request: Encodable {
        struct Arguments: Encodable {
            let from: String
            let to: String
            let dryRun: Bool
        }

        let name = "_migrate_project"
        let arguments: Arguments
    }

    private struct Failure: Decodable {
        let toolError: String
    }
}
