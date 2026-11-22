import Foundation

public enum RecallHook {
    private struct Input: Decodable {
        let cwd: String
        let prompt: String
        let session_id: String?
    }

    private struct AntigravityInput: Decodable {
        let cwd: String?
        let workspacePaths: [String]?
        let lastUserInput: String?
        let conversationId: String?
    }

    public static func output(for input: Data, socket: URL = MemoryPaths.socket) throws -> Data? {
        let event = try Wire.decode(Input.self, input)
        let query = event.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard event.cwd.hasPrefix("/"), !shouldSkip(query), !isLowInformation(query) else { return nil }
        guard let context = try fetchContext(query: query, project: event.cwd,
                                             threadID: event.session_id ?? "", agent: "codex", socket: socket) else {
            return nil
        }
        return try JSONSerialization.data(withJSONObject: [
            "hookSpecificOutput": ["hookEventName": "UserPromptSubmit", "additionalContext": context]
        ])
    }

    public static func antigravityOutput(for input: Data, socket: URL = MemoryPaths.socket) throws -> Data {
        let empty = Data("{}".utf8)
        guard let event = try? Wire.decode(AntigravityInput.self, input) else { return empty }
        let project = (event.cwd?.hasPrefix("/") == true ? event.cwd : nil)
            ?? event.workspacePaths?.first(where: { $0.hasPrefix("/") })
            ?? ""
        let query = (event.lastUserInput ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard project.hasPrefix("/"), !shouldSkip(query) else { return empty }
        // The store also handles short replies so Antigravity can associate the conversation
        // with its workspace for capture, without running a memory search.
        guard let context = try? fetchContext(query: query, project: project,
                                              threadID: event.conversationId ?? "", agent: "antigravity", socket: socket) else {
            return empty
        }
        return try JSONSerialization.data(withJSONObject: [
            "injectSteps": [
                ["systemMessage": ["systemMessage": context]]
            ]
        ])
    }

    private static let lowInformationPrompts: Set<String> = [
        "好", "好的", "好啊", "好呀", "嗯", "嗯嗯", "是的", "对", "对的", "行", "可以", "收到",
        "知道了", "明白", "明白了", "继续", "继续吧", "谢谢", "谢谢你", "感谢", "辛苦了", "没问题",
        "你好", "您好", "嗨", "再见", "ok", "okay", "yes", "yep", "no", "nope", "sure", "continue",
        "goahead", "thanks", "thankyou", "thx", "gotit", "hi", "hello", "hey", "bye", "👍", "👌"
    ]

    static func isLowInformation(_ query: String) -> Bool {
        // Match complete replies so short domain queries and confirmations with details still work.
        let normalized = query.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation }
        return normalized.isEmpty || lowInformationPrompts.contains(normalized)
    }

    private static func shouldSkip(_ query: String) -> Bool {
        query.isEmpty || SecretFilter.contains(query) ||
            query.hasPrefix("/") || query.contains("agent-memory MCP") ||
            query.hasPrefix("Agent Memory · 批量做梦") ||
            query.hasPrefix(CodexSetup.setupPromptTitle) ||
            query.hasPrefix(AntigravitySetup.setupPromptTitle) ||
            query.contains(AntigravitySetup.verifyQuery)
    }

    private static func fetchContext(query: String, project: String, threadID: String,
                                     agent: String, socket: URL) throws -> String? {
        let request = try JSONSerialization.data(withJSONObject: [
            "name": "_recall_context", "arguments": [
                "query": String(query.prefix(1000)), "project": project,
                "threadID": threadID, "agent": agent
            ]
        ])
        let reply = try Wire.decode([String: String].self, LocalConnection.call(request, socket: socket, timeout: 2))
        guard let context = reply["context"], !context.isEmpty else { return nil }
        return context
    }
}
