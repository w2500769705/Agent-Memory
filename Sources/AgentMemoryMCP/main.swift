import AgentMemoryCore
import Foundation

let socket = ProcessInfo.processInfo.environment["AGENT_MEMORY_SOCKET"]
    .map { URL(fileURLWithPath: $0) } ?? MemoryPaths.socket

switch CommandLine.arguments.dropFirst().first {
case "--locate-codex":
    do {
        print(try CodexSource.executable().path)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        exit(1)
    }
case "--recall-hook":
    let input = FileHandle.standardInput.readDataToEndOfFile()
    if input.count <= 1_000_000, let output = try? RecallHook.output(for: input, socket: socket) {
        try? FileHandle.standardOutput.write(contentsOf: output)
    }
    exit(0)
case "--recall-hook-antigravity":
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let output = (input.count <= 1_000_000 ? (try? RecallHook.antigravityOutput(for: input, socket: socket)) : nil) ?? Data("{}".utf8)
    try? FileHandle.standardOutput.write(contentsOf: output)
    exit(0)
case "--setup-codex":
    do {
        let bridge = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        try CodexSetup.connect(bridge: bridge)
        try CodexSetup.installHook(bridge: bridge)
        try CodexSetup.setRecall(true, socket: socket)
        let status = try CodexSetup.verify(bridge: bridge, socket: socket)
        guard status.toolsAvailable else { throw MemoryError.invalid("Codex 尚未发现 Agent Memory 工具。") }
        print("MCP 工具已发现。请在 Codex 的「设置 → 勾子（Hooks）」审核 UserPromptSubmit，再回到 Agent Memory 发送验证指令。")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        exit(1)
    }
case "--setup-antigravity":
    do {
        let bridge = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        try AntigravitySetup.connect(bridge: bridge)
        try AntigravitySetup.installHook(bridge: bridge)
        try AntigravitySetup.setRecall(true, socket: socket)
        let status = try AntigravitySetup.verify(bridge: bridge, socket: socket)
        guard status.toolsAvailable else {
            throw MemoryError.invalid("MCP 配置已写入，但尚未连接到运行中的 Agent Memory。请先打开 Agent Memory 应用。")
        }
        print("Antigravity MCP 与自动检索 Hook 已写入（~/.gemini/config/）。请在 Antigravity 刷新 MCP Servers 并新开对话，发送「\(AntigravitySetup.testPrompt)」完成自动检索验证。")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        exit(1)
    }
case ProjectMigrationCommand.flag:
    do {
        let result = try ProjectMigrationCommand.run(arguments: Array(CommandLine.arguments.dropFirst(2)), socket: socket)
        print(String(decoding: result, as: UTF8.self))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        exit(1)
    }
default:
    break
}

func reply(_ message: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
    data.append(10)
    try? FileHandle.standardOutput.write(contentsOf: data)
}

func toolResult(_ data: Data) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw MemoryError.invalid("应用返回了无效结果。")
    }
    if let error = value["toolError"] as? String {
        return ["isError": true, "content": [["type": "text", "text": error]]]
    }
    return ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]], "structuredContent": value]
}

let supportedVersions = ["2025-03-26", "2025-06-18", "2025-11-25"]
var clientAgent: ActivityEvent.Agent?
while let line = readLine() {
    guard line.utf8.count <= 2_000_000,
          let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
          let id = message["id"] else { continue }
    let method = message["method"] as? String
    let params = message["params"] as? [String: Any] ?? [:]
    var envelope: [String: Any] = ["jsonrpc": "2.0", "id": id]
    switch method {
    case "initialize":
        let clientInfo = params["clientInfo"] as? [String: Any]
        let clientName = (clientInfo?["name"] as? String)?.lowercased() ?? ""
        if clientName.contains("antigravity") { clientAgent = .antigravity }
        else if clientName.contains("codex") { clientAgent = .codex }
        else { clientAgent = nil }
        let requested = params["protocolVersion"] as? String ?? ""
        envelope["result"] = [
            "protocolVersion": supportedVersions.contains(requested) ? requested : supportedVersions[2],
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "agent-memory", "version": "0.1.0"],
            "instructions": MCPTools.instructions
        ]
    case "ping": envelope["result"] = [:] as [String: Any]
    case "tools/list": envelope["result"] = ["tools": MCPTools.definitions]
    case "tools/call":
        do {
            guard let name = params["name"] as? String,
                  MCPTools.definitions.contains(where: { $0["name"] as? String == name }) else {
                throw MemoryError.invalid("未知工具。")
            }
            var request = params
            request["agent"] = clientAgent?.rawValue
            let data = try JSONSerialization.data(withJSONObject: request)
            envelope["result"] = try toolResult(LocalConnection.call(data, socket: socket))
        } catch {
            envelope["result"] = ["isError": true, "content": [["type": "text", "text": error.localizedDescription]]]
        }
    default:
        envelope["error"] = ["code": -32601, "message": "Method not found"]
    }
    reply(envelope)
}
