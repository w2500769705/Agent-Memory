import Foundation

public struct CodexConnectionStatus: Sendable {
    public let registered: Bool
    public let toolsAvailable: Bool
    public let recallInstalled: Bool
    public let hookStatus: String?
    public let hookError: String?
}

public enum CodexSetup {
    public static let testPrompt = "Agent Memory · 验证自动检索"
    public static let setupPromptTitle = "Agent Memory · 配置 Codex"
    static let serverName = "agent-memory"
    static let hookFlag = "--recall-hook"
    private static let hookDescription = "Agent Memory 自动检索"

    public static var home: URL {
        ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap {
            $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil
        } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func verify(bridge: URL, socket: URL = MemoryPaths.socket) throws -> CodexConnectionStatus {
        let executable = try CodexSource.executable()
        let registered = try registration(bridge: bridge, executable: executable)
        var recall = false
        var hookError: String?
        do { recall = try hookInstalled(bridge: bridge) }
        catch { hookError = "无法读取 Codex Hooks 配置。请检查 hooks.json 后重试。" }
        var available = false
        var hookStatus: String?
        if registered || recall {
            let rpc = try CodexRPC(executable: executable)
            if registered {
                let result = try rpc.call("mcpServerStatus/list", ["serverName": serverName, "detail": "toolsAndAuthOnly"])
                let servers = result["data"] as? [[String: Any]] ?? []
                let discovered = servers.contains { server in
                    let tools = server["tools"] as? [String: Any] ?? [:]
                    return server["name"] as? String == serverName &&
                        ["memory_search", "dream_get_batch", "dream_submit"].allSatisfy { tools[$0] != nil }
                }
                let probe = Data(#"{"name":"_connection_probe"}"#.utf8)
                let response = try? LocalConnection.call(probe, socket: socket, timeout: 2)
                available = discovered && response.flatMap { try? Wire.decode([String: String].self, $0) }?["status"] == "ok"
            }
            if recall, let result = try? rpc.call("hooks/list", [
                "cwds": [FileManager.default.homeDirectoryForCurrentUser.path]
            ]) {
                let groups = result["data"] as? [[String: Any]] ?? []
                let hooks = groups.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
                if let hook = hooks.first(where: {
                    $0["eventName"] as? String == "userPromptSubmit" && $0["command"] as? String == hookCommand(bridge)
                }) {
                    hookStatus = hook["enabled"] as? Bool == false && hook["trustStatus"] as? String == "trusted"
                        ? "disabled" : hook["trustStatus"] as? String
                } else {
                    hookStatus = "unavailable"
                }
            }
        }
        return CodexConnectionStatus(registered: registered, toolsAvailable: available, recallInstalled: recall,
                                     hookStatus: hookStatus, hookError: hookError)
    }

    public static func connect(bridge: URL) throws {
        let executable = try CodexSource.executable()
        if try !registration(bridge: bridge, executable: executable) {
            _ = try run(executable, ["mcp", "add", serverName, "--", bridge.path])
        }
    }

    private static func registration(bridge: URL, executable: URL) throws -> Bool {
        let list = try JSONSerialization.jsonObject(with: run(executable, ["mcp", "list", "--json"]))
        guard let servers = list as? [[String: Any]] else {
            throw MemoryError.invalid("无法读取 Codex 的 MCP 配置。")
        }
        guard let server = servers.first(where: { $0["name"] as? String == serverName }) else { return false }
        let transport = server["transport"] as? [String: Any]
        guard let command = transport?["command"] as? String,
              URL(fileURLWithPath: command).resolvingSymlinksInPath().path == bridge.resolvingSymlinksInPath().path else {
            throw MemoryError.invalid("Codex 中已有同名 MCP，路径与此应用不同。请在 Codex 检查该条配置。")
        }
        guard server["enabled"] as? Bool == true else {
            throw MemoryError.invalid("Agent Memory 已注册，请在 Codex 的 MCP 设置中启用。")
        }
        return true
    }

    private static func run(_ executable: URL, _ arguments: [String]) throws -> Data {
        let output = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: timeout)
        defer { timeout.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw MemoryError.invalid("Codex 未能完成配置命令。") }
        return data
    }

    public static func hookInstalled(bridge: URL, home: URL = home) throws -> Bool {
        let (root, _) = try loadHooks(home: home)
        return try hookGroups(root).contains { group in containsHook(group, bridge: bridge) }
    }

    public static func installHook(bridge: URL, home: URL = home) throws {
        var (root, original) = try loadHooks(home: home)
        var groups = try hookGroups(root)
        guard !groups.contains(where: { containsHook($0, bridge: bridge) }) else { return }
        groups.append(["hooks": [
            ["type": "command", "command": hookCommand(bridge), "timeout": 4]
        ]])
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        hooks["UserPromptSubmit"] = groups
        root["hooks"] = hooks
        if root["description"] == nil { root["description"] = hookDescription }
        try writeHooks(root, original: original, home: home)
    }

    public static func removeHook(bridge: URL, home: URL = home) throws {
        var (root, original) = try loadHooks(home: home)
        let groups = try hookGroups(root)
        guard groups.contains(where: { containsHook($0, bridge: bridge) }) else { return }
        let filtered = groups.compactMap { group -> [String: Any]? in
            guard let handlers = group["hooks"] as? [[String: Any]],
                  containsHook(group, bridge: bridge) else { return group }
            var copy = group
            let remaining = handlers.filter { !isHook($0, bridge: bridge) }
            guard !remaining.isEmpty else { return nil }
            copy["hooks"] = remaining
            return copy
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        hooks["UserPromptSubmit"] = filtered.isEmpty ? nil : filtered
        root["hooks"] = hooks
        try writeHooks(root, original: original, home: home)
    }

    private static func containsHook(_ group: [String: Any], bridge: URL) -> Bool {
        (group["hooks"] as? [[String: Any]] ?? []).contains { isHook($0, bridge: bridge) }
    }

    private static func isHook(_ handler: [String: Any], bridge: URL) -> Bool {
        handler["type"] as? String == "command" && handler["command"] as? String == hookCommand(bridge)
    }

    private static func writeHooks(_ root: [String: Any], original: Data?, home: URL) throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let path = home.appendingPathComponent("hooks.json")
        if let original {
            let backup = home.appendingPathComponent("hooks.agent-memory-backup-" + UUID().uuidString + ".json")
            try original.write(to: backup, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    private static func hookCommand(_ bridge: URL) -> String { shellQuote(bridge.path) + " " + hookFlag }

    private static func loadHooks(home: URL) throws -> ([String: Any], Data?) {
        let path = home.appendingPathComponent("hooks.json")
        let original: Data
        do { original = try Data(contentsOf: path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return ([:], nil)
        }
        guard let root = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
            throw MemoryError.invalid("hooks.json 不是有效的 JSON 对象。")
        }
        return (root, original)
    }

    private static func hookGroups(_ root: [String: Any]) throws -> [[String: Any]] {
        guard let hooks = root["hooks"] else { return [] }
        guard let events = hooks as? [String: Any] else { throw MemoryError.invalid("现有 Hooks 配置格式无效。") }
        guard let matchers = events["UserPromptSubmit"] else { return [] }
        guard let groups = matchers as? [[String: Any]] else {
            throw MemoryError.invalid("现有 UserPromptSubmit 配置格式无效。")
        }
        return groups
    }

    public static func setRecall(_ enabled: Bool, socket: URL = MemoryPaths.socket) throws {
        let request = try JSONSerialization.data(withJSONObject: [
            "name": "_configure_recall", "arguments": ["enabled": enabled]
        ])
        let response = try Wire.decode([String: String].self, LocalConnection.call(request, socket: socket))
        if let error = response["toolError"] { throw MemoryError.invalid(error) }
        guard response["status"] == "ok" else { throw MemoryError.invalid("Agent Memory 未返回确认。") }
    }

    public static var testURL: URL? {
        var components = URLComponents()
        components.scheme = "codex"
        components.host = "threads"
        components.path = "/new"
        components.queryItems = [URLQueryItem(name: "prompt", value: testPrompt)]
        return components.url
    }
}
