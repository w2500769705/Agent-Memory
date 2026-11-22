import Foundation

public struct ScanResult: Sendable {
    public let inserted: Int
    public let skippedThreads: Int
    public let scannedThreads: Int
}

public enum CodexSource {
    private static let batchDreamPrefix = "Agent Memory · 批量做梦"

    public static func batchDreamPrompt(through: Int64) -> String {
        """
        \(batchDreamPrefix)

        使用 agent-memory MCP，分批处理点击时所有项目的待做梦记录。
        每次用 dream_get_batch 传入 limit: 8、through: \(through)，省略 project。
        依据证据提炼可复用的记忆。每条记录都要有处置，临时内容用 skip。
        每批用 dream_submit 提交成功后再领下一批。领取返回 empty 时结束。
        如果工具出错，或提交返回版本冲突，停止继续领取并说明原因，保留已提交的批次。
        最后汇报处理的批次、写入、待确认和跳过数量。
        """
    }

    public static func batchDreamURL(through: Int64) -> URL? {
        var components = URLComponents()
        components.scheme = "codex"
        components.host = "threads"
        components.path = "/new"
        components.queryItems = [URLQueryItem(name: "prompt", value: batchDreamPrompt(through: through))]
        return components.url
    }

    public static func executable() throws -> URL {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path
        let app = "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .filter { $0.hasPrefix("/") }.map { "\($0)/codex" } +
            ["\(home)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
             "/Applications/ChatGPT.app/\(app)", "\(home)/Applications/ChatGPT.app/\(app)",
             "/Applications/Codex.app/\(app)", "/Applications/Codex.app/Contents/Resources/codex"]
        guard let path = paths.first(where: fileManager.isExecutableFile(atPath:)) else {
            throw MemoryError.invalid("未找到本机 Codex。请安装 Codex 桌面应用或 CLI。")
        }
        return URL(fileURLWithPath: path)
    }

    public static func hasRecentActivity(since: Double, codexHome: URL = CodexSetup.home) -> Bool {
        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: codexHome.path, isDirectory: &isDir), isDir.boolValue else {
            return true
        }
        let ignoredDirs: Set<String> = ["cache", "tmp", "logs", "log", "plugins", "skills", "rules", "bin"]
        let ignoredFiles: Set<String> = ["config.toml", "hooks.json", "auth.json", "version.json", ".DS_Store"]
        let cutoff = since - 2
        guard let enumerator = fileManager.enumerator(
            at: codexHome,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return true
        }
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey]) else {
                continue
            }
            let name = url.lastPathComponent
            if values.isDirectory == true {
                if ignoredDirs.contains(name.lowercased()) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true, !ignoredFiles.contains(name) else { continue }
            if let mtime = values.contentModificationDate, mtime.timeIntervalSince1970 >= cutoff {
                return true
            }
        }
        return false
    }

    public static func scan(
        store: MemoryStore,
        executable override: URL? = nil,
        force: Bool = false,
        codexHome: URL = CodexSetup.home
    ) throws -> ScanResult {
        do {
            return try scanEnabled(store: store, executable: override, force: force, codexHome: codexHome)
        } catch {
            store.recordError(error, operation: "采集失败", agent: .codex)
            throw error
        }
    }

    private static func scanEnabled(store: MemoryStore, executable override: URL?, force: Bool,
                                    codexHome: URL) throws -> ScanResult {
        guard try store.setting("enabled") == "1", let raw = try store.setting("scanSince"), let since = Double(raw) else {
            return ScanResult(inserted: 0, skippedThreads: 0, scannedThreads: 0)
        }
        if !force && override == nil && !hasRecentActivity(since: since, codexHome: codexHome) {
            return ScanResult(inserted: 0, skippedThreads: 0, scannedThreads: 0)
        }
        let checkpoint = Date().timeIntervalSince1970
        let source = try CodexRPC(executable: override ?? executable())
        var cursor: String?
        var evidence: [Evidence] = []
        var skipped = 0
        var scanned = 0
        let projects = Set((try store.setting("excludedProjects") ?? "").split(separator: "\n").map(String.init))
        let threads = Set((try store.setting("excludedThreads") ?? "").split(separator: "\n").map(String.init))
        repeat {
            var arguments: [String: Any] = ["limit": 50, "archived": false, "sortKey": "updated_at", "modelProviders": []]
            if let cursor { arguments["cursor"] = cursor }
            let response = try source.call("thread/list", arguments)
            guard let records = response["data"] as? [[String: Any]] else {
                throw MemoryError.invalid("Codex 返回了无法读取的聊天列表。")
            }
            var reachedCutoff = false
            for thread in records {
                guard let id = thread["id"] as? String else { continue }
                if let updated = thread["updatedAt"] as? Double, updated < since - 2 { reachedCutoff = true; break }
                guard !threads.contains(id), thread["parentThreadId"] as? String == nil,
                      thread["ephemeral"] as? Bool != true, let cwd = thread["cwd"] as? String else { continue }
                let project = ProjectIdentity.resolve(cwd)
                guard !project.isEmpty, !projects.contains(project) else { continue }
                do {
                    evidence += try recordsForThread(source, id: id, project: project, since: since)
                    scanned += 1
                } catch let error as CodexRPC.RemoteError {
                    if error.code == -32601 { throw error }
                    if error.code == -32600 || error.code == -32602 { skipped += 1 }
                    else { throw error }
                }
            }
            let next = reachedCutoff ? nil : response["nextCursor"] as? String
            if next == cursor { break }
            cursor = next
        } while cursor != nil
        // Keep a short overlap for threads whose durable history is published after a scan.
        let next = skipped > 0 ? since : max(since, checkpoint - 120)
        let count = try store.ingest(evidence, scannedFrom: since, checkpoint: next,
                                     enabledKey: "enabled", cursorKey: "scanSince",
                                     scanAgent: scanned > 0 || skipped > 0 ? .codex : nil)
        return ScanResult(inserted: count, skippedThreads: skipped, scannedThreads: scanned)
    }

    private static func recordsForThread(_ source: CodexRPC, id: String, project: String, since: Double) throws -> [Evidence] {
        var cursor: String?
        var out: [Evidence] = []
        repeat {
            var arguments: [String: Any] = ["threadId": id, "limit": 30, "itemsView": "full", "sortDirection": "desc"]
            if let cursor { arguments["cursor"] = cursor }
            let result = try source.call("thread/turns/list", arguments)
            guard let turns = result["data"] as? [[String: Any]] else {
                throw MemoryError.invalid("Codex 返回了无法读取的聊天轮次。")
            }
            var older = false
            for turn in turns {
                let time = (turn["completedAt"] as? Double) ?? (turn["startedAt"] as? Double)
                if let time, time < since { older = true; continue }
                guard let time, let item = evidence(turn: turn, threadID: id, project: project, timestamp: time) else { continue }
                out.append(item)
            }
            let next = older ? nil : result["nextCursor"] as? String
            if next == cursor { break }
            cursor = next
        } while cursor != nil
        return out
    }

    package static func evidence(turn: [String: Any], threadID: String, project: String, timestamp: Double) -> Evidence? {
        guard turn["status"] as? String == "completed", let id = turn["id"] as? String,
              let items = turn["items"] as? [[String: Any]] else { return nil }
        let dreamTools = ["dream_get_batch", "dream_submit"]
        if items.contains(where: { item in
            (item["type"] as? String) == "mcpToolCall" &&
            (item["tool"] as? String).map(dreamTools.contains) == true
        }) { return nil }
        let user = items.filter { $0["type"] as? String == "userMessage" }
            .flatMap { $0["content"] as? [[String: Any]] ?? [] }
            .filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let final = items.reversed().first { item in
            item["type"] as? String == "agentMessage" &&
                (item["phase"] as? String == "final_answer" || item["phase"] is NSNull || item["phase"] == nil)
        }?["text"] as? String ?? ""
        guard !user.isEmpty, !SecretFilter.contains(user), !SecretFilter.contains(final) else { return nil }
        if user.hasPrefix(batchDreamPrefix) || user.hasPrefix(CodexSetup.setupPromptTitle) ||
            user.hasPrefix(AntigravitySetup.setupPromptTitle) ||
            user == CodexSetup.testPrompt || user == AntigravitySetup.verifyPrompt ||
            user.contains(AntigravitySetup.verifyQuery) { return nil }
        if user.range(of: #"(?i)\bdream-[0-9a-f]{8}-[0-9a-f-]{27}\b"#, options: .regularExpression) != nil ||
            final.range(of: #"(?i)\bdream-[0-9a-f]{8}-[0-9a-f-]{27}\b"#, options: .regularExpression) != nil { return nil }
        if ["帮我做梦", "做梦", "帮我把这批记忆做梦并写回", "使用 agent-memory MCP 工具帮我做梦，并写回这一批结果"]
            .contains(user.trimmingCharacters(in: .punctuationCharacters)) { return nil }
        let excerpt = "用户\n" + String(user.prefix(1400)) + (final.isEmpty ? "" : "\n\nCodex\n" + String(final.prefix(900)))
        return Evidence(id: "codex:\(threadID):\(id)", threadID: threadID, turnID: id,
                        project: project, timestamp: timestamp, excerpt: excerpt)
    }
}

final class CodexRPC {
    struct RemoteError: LocalizedError {
        let code: Int
        var errorDescription: String? { "Codex App Server 返回错误（\(code)）。" }
    }

    private let transport: LineProcess
    private var nextID = 0

    init(executable: URL) throws {
        transport = try LineProcess(executable: executable, arguments: ["app-server", "--stdio"], name: "Codex App Server")
        _ = try call("initialize", ["clientInfo": ["name": "agent_memory", "version": "0.1.0"]])
        try send(["method": "initialized"])
    }

    func call(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        nextID += 1
        let id = nextID
        try send(["id": id, "method": method, "params": params])
        let deadline = DispatchTime.now().uptimeNanoseconds + 20_000_000_000
        while true {
            let line = try transport.readLine(deadline: deadline)
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  message["id"] as? Int == id else { continue }
            if let error = message["error"] as? [String: Any] { throw RemoteError(code: error["code"] as? Int ?? 0) }
            guard let result = message["result"] as? [String: Any] else {
                throw MemoryError.invalid("Codex App Server 响应缺少结果。")
            }
            return result
        }
    }

    private func send(_ payload: [String: Any]) throws {
        try transport.writeLine(JSONSerialization.data(withJSONObject: payload))
    }
}
