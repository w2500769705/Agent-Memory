import Foundation

public struct AntigravityConnectionStatus: Sendable {
    public let registered: Bool
    public let toolsAvailable: Bool
    public let recallInstalled: Bool
    public let hookError: String?
    public let configPath: String
}

public enum AntigravitySetup {
    public static let testPrompt = "Agent Memory · 验证自动检索"
    public static let setupPromptTitle = "Agent Memory · 配置 Antigravity"
    public static let verifyQuery = "Agent Memory · 验证 Antigravity MCP"
    public static let verifyPrompt = "请调用 agent-memory MCP 的 memory_search 工具，传入 query: \"\(verifyQuery)\"（保持原样不要改写），并返回检索结果以完成 Antigravity 连接验证。"
    static let serverName = "agent-memory"
    static let hookName = "agent-memory"
    static let hookFlag = "--recall-hook-antigravity"

    public static var configDirectory: URL {
        ProcessInfo.processInfo.environment["ANTIGRAVITY_CONFIG_DIR"].flatMap {
            $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil
        } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/config", isDirectory: true)
    }

    public static func configFile(in directory: URL = configDirectory) -> URL {
        directory.appendingPathComponent("mcp_config.json")
    }

    public static func hooksFile(in directory: URL = configDirectory) -> URL {
        directory.appendingPathComponent("hooks.json")
    }

    public static func verify(bridge: URL, socket: URL = MemoryPaths.socket,
                              configDir: URL = configDirectory) throws -> AntigravityConnectionStatus {
        let registered = try registration(bridge: bridge, configDir: configDir)
        var recall = false
        var hookError: String?
        do { recall = try hookInstalled(bridge: bridge, configDir: configDir) }
        catch { hookError = "无法读取 Antigravity Hooks 配置。请检查 ~/.gemini/config/hooks.json 后重试。" }
        var available = false
        if registered {
            let discovered = (try? probeBridgeTools(bridge: bridge)) == true
            let probe = Data(#"{"name":"_connection_probe"}"#.utf8)
            let response = try? LocalConnection.call(probe, socket: socket, timeout: 2)
            let socketOK = response.flatMap { try? Wire.decode([String: String].self, $0) }?["status"] == "ok"
            available = discovered && socketOK
        }
        return AntigravityConnectionStatus(registered: registered, toolsAvailable: available,
                                           recallInstalled: recall, hookError: hookError,
                                           configPath: configFile(in: configDir).path)
    }

    public static func connect(bridge: URL, configDir: URL = configDirectory) throws {
        if try registration(bridge: bridge, configDir: configDir) { return }
        var (root, original) = try loadJSON(at: configFile(in: configDir), label: "mcp_config.json")
        var servers = try mcpServers(root)
        servers[serverName] = ["command": bridge.path]
        root["mcpServers"] = servers
        try writeJSON(root, original: original, to: configFile(in: configDir), backupPrefix: "mcp_config")
    }

    public static func disconnect(bridge: URL, configDir: URL = configDirectory) throws {
        guard try registration(bridge: bridge, configDir: configDir) else { return }
        var (root, original) = try loadJSON(at: configFile(in: configDir), label: "mcp_config.json")
        var servers = try mcpServers(root)
        servers.removeValue(forKey: serverName)
        root["mcpServers"] = servers
        try writeJSON(root, original: original, to: configFile(in: configDir), backupPrefix: "mcp_config")
    }

    public static func registration(bridge: URL, configDir: URL = configDirectory) throws -> Bool {
        let (root, _) = try loadJSON(at: configFile(in: configDir), label: "mcp_config.json")
        let servers = try mcpServers(root)
        guard let rawServer = servers[serverName] else { return false }
        guard let server = rawServer as? [String: Any] else {
            throw MemoryError.invalid("Antigravity 的 agent-memory MCP 配置格式无效。")
        }
        guard let command = server["command"] as? String,
              URL(fileURLWithPath: command).resolvingSymlinksInPath().path == bridge.resolvingSymlinksInPath().path else {
            throw MemoryError.invalid("Antigravity 中已有同名 MCP，路径与此应用不同。请检查 ~/.gemini/config/mcp_config.json。")
        }
        if let args = server["args"] as? [Any], !args.isEmpty {
            throw MemoryError.invalid("Antigravity 中已有同名 MCP，参数与此应用不同。请检查 ~/.gemini/config/mcp_config.json。")
        }
        if server["disabled"] as? Bool == true {
            throw MemoryError.invalid("Agent Memory 已注册，但在 Antigravity 的 MCP 配置中处于停用状态。")
        }
        return true
    }

    public static func hookInstalled(bridge: URL, configDir: URL = configDirectory) throws -> Bool {
        let (root, _) = try loadJSON(at: hooksFile(in: configDir), label: "hooks.json")
        guard let rawSpec = root[hookName] else { return false }
        guard let spec = rawSpec as? [String: Any] else {
            throw MemoryError.invalid("现有 Antigravity hooks.json 中的 agent-memory 配置格式无效。")
        }
        if spec["enabled"] as? Bool == false { return false }
        guard let rawHandlers = spec["PreInvocation"] else { return false }
        guard let handlers = rawHandlers as? [[String: Any]] else {
            throw MemoryError.invalid("现有 Antigravity PreInvocation 配置格式无效。")
        }
        return handlers.contains { isHook($0, bridge: bridge) }
    }

    public static func installHook(bridge: URL, configDir: URL = configDirectory) throws {
        var (root, original) = try loadJSON(at: hooksFile(in: configDir), label: "hooks.json")
        var spec = (root[hookName] as? [String: Any]) ?? [:]
        if root[hookName] != nil && root[hookName] as? [String: Any] == nil {
            throw MemoryError.invalid("现有 Antigravity hooks.json 中的 agent-memory 配置格式无效。")
        }
        var handlers: [[String: Any]] = []
        if let raw = spec["PreInvocation"] {
            guard let existing = raw as? [[String: Any]] else {
                throw MemoryError.invalid("现有 Antigravity PreInvocation 配置格式无效。")
            }
            handlers = existing
        }
        let alreadyInstalled = spec["enabled"] as? Bool != false && handlers.contains { isHook($0, bridge: bridge) }
        guard !alreadyInstalled else { return }
        if !handlers.contains(where: { isHook($0, bridge: bridge) }) {
            handlers.append(["type": "command", "command": hookCommand(bridge), "timeout": 4])
        }
        spec["PreInvocation"] = handlers
        spec.removeValue(forKey: "enabled")
        root[hookName] = spec
        try writeJSON(root, original: original, to: hooksFile(in: configDir), backupPrefix: "hooks")
    }

    public static func removeHook(bridge: URL, configDir: URL = configDirectory) throws {
        var (root, original) = try loadJSON(at: hooksFile(in: configDir), label: "hooks.json")
        guard var spec = root[hookName] as? [String: Any],
              let handlers = spec["PreInvocation"] as? [[String: Any]],
              handlers.contains(where: { isHook($0, bridge: bridge) }) else { return }
        let remaining = handlers.filter { !isHook($0, bridge: bridge) }
        if remaining.isEmpty {
            spec.removeValue(forKey: "PreInvocation")
        } else {
            spec["PreInvocation"] = remaining
        }
        if spec.isEmpty {
            root.removeValue(forKey: hookName)
        } else {
            root[hookName] = spec
        }
        try writeJSON(root, original: original, to: hooksFile(in: configDir), backupPrefix: "hooks")
    }

    public static func setRecall(_ enabled: Bool, socket: URL = MemoryPaths.socket) throws {
        let request = try JSONSerialization.data(withJSONObject: [
            "name": "_configure_recall", "arguments": ["enabled": enabled, "agent": "antigravity"]
        ])
        let response = try Wire.decode([String: String].self, LocalConnection.call(request, socket: socket))
        if let error = response["toolError"] { throw MemoryError.invalid(error) }
        guard response["status"] == "ok" else { throw MemoryError.invalid("Agent Memory 未返回确认。") }
    }

    private static func hookCommand(_ bridge: URL) -> String {
        CodexSetup.shellQuote(bridge.path) + " " + hookFlag
    }

    private static func isHook(_ handler: [String: Any], bridge: URL) -> Bool {
        let type = handler["type"] as? String ?? "command"
        return type == "command" && handler["command"] as? String == hookCommand(bridge)
    }

    private static func probeBridgeTools(bridge: URL) throws -> Bool {
        let transport = try LineProcess(executable: bridge, arguments: [], name: "Agent Memory MCP")
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000

        func request(_ id: Int, method: String, params: [String: Any] = [:]) throws -> [String: Any] {
            let payload: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
            try transport.writeLine(JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes]))
            while true {
                let line = try transport.readLine(deadline: deadline)
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      message["id"] as? Int == id else { continue }
                guard let result = message["result"] as? [String: Any] else {
                    throw MemoryError.invalid("Agent Memory MCP 未返回有效结果。")
                }
                return result
            }
        }

        _ = try request(1, method: "initialize", params: [
            "protocolVersion": "2025-11-25",
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "agent_memory_probe", "version": "0.1.0"]
        ])
        let list = try request(2, method: "tools/list")
        let tools = list["tools"] as? [[String: Any]] ?? []
        let names = Set(tools.compactMap { $0["name"] as? String })
        return ["memory_search", "dream_get_batch", "dream_submit"].allSatisfy { names.contains($0) }
    }

    private static func loadJSON(at path: URL, label: String) throws -> ([String: Any], Data?) {
        let original: Data
        do { original = try Data(contentsOf: path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return ([:], nil)
        }
        guard let root = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
            throw MemoryError.invalid("\(label) 不是有效的 JSON 对象。")
        }
        return (root, original)
    }

    private static func mcpServers(_ root: [String: Any]) throws -> [String: Any] {
        guard let raw = root["mcpServers"] else { return [:] }
        guard let servers = raw as? [String: Any] else {
            throw MemoryError.invalid("mcp_config.json 中的 mcpServers 格式无效。")
        }
        return servers
    }

    private static func writeJSON(_ root: [String: Any], original: Data?, to path: URL, backupPrefix: String) throws {
        let dir = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        if let original {
            let backup = dir.appendingPathComponent("\(backupPrefix).agent-memory-backup-" + UUID().uuidString + ".json")
            try original.write(to: backup, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
}
