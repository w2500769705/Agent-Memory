import Foundation
import SQLite3
import AgentMemoryCore

@main
struct MemoryFlowTests {
    static func main() throws {
        let tests = Self()
        try tests.testCaptureSubmitSemanticRetrievalAndUndo()
        try tests.testStaleUpdateDoesNotOverwriteAndRequeuesEvidence()
        try tests.testScopeAndExclusionAreValidated()
        tests.testCodexEvidenceUsesFinalOutputAndSkipsDreams()
        try tests.testCodexScanCheckpointAndDeduplication()
        try tests.testMCPWritesViaSocket()
        try tests.testBulkDreamSnapshot()
        try tests.testLargeMCPBatch()
        try tests.testGuidedRecall()
        try tests.testAntigravityMCPSetup()
        try tests.testAntigravityRecallAndCapture()
        try tests.testSmartCaptureAndIncrementalRead()
        try tests.testRecallVersionsAndActivityLog()
        try tests.testRecallIgnoresGenericQuestionsAndFindsSpecificMemories()
        try tests.testRecallVectorThresholdsAndKeywordFallback()
        try tests.testRecallDoesNotBackfillAfterDeduplication()
        try tests.testLegacyMemoryStatisticsMigration()
        try tests.testVectorCacheInspectionAndMemoryHealth()
        try tests.testDreamBatchSummariesAndLookups()
        print("通过 19 项冒烟测试")
    }

    let project = "/tmp/agent-memory-demo"

    private func proof(_ number: Int, text: String, project: String? = nil) -> Evidence {
        .init(id: "proof-\(number)", threadID: "thread-\(number)", turnID: "turn-\(number)",
              project: project ?? self.project, timestamp: Double(number), excerpt: text)
    }

    private func add(_ evidence: Evidence, title: String, body: String) -> Proposal {
        .init(operation: .add, evidenceIDs: [evidence.id], reason: "用户已确认",
              scope: "project", project: evidence.project, title: title, body: body)
    }

    func testCaptureSubmitSemanticRetrievalAndUndo() throws {
        let store = try MemoryStore(path: ":memory:")
        let first = proof(1, text: "我测试 Android 的时候需要可以直接覆盖升级，用已有项目签名。")
        let unrelated = proof(2, text: "Jellyfin 用环绕音响。", project: "/tmp/elsewhere")
        expectEqual(try store.ingest([first, unrelated, first]), 2)
        expectEqual(try store.dashboard().pending, 2)
        let batch = try unwrap(store.getBatch(project: project))
        expectEqual(batch.evidence.map(\.id), [first.id])
        let proposal = add(first, title: "签名 APK 交付", body: "Android 测试包使用项目签名的 release APK，以便覆盖安装。版本 v0.12.2。")
        let result = try store.submit(batchID: batch.id, proposals: [proposal])
        expectEqual(result.decisions.first?.status, "applied")
        expectEqual(try store.submit(batchID: batch.id, proposals: [proposal]).decisions.first?.id,
                       result.decisions.first?.id)
        let distractor = proof(3, text: "影院播放电影时有环绕声。")
        try store.ingest([distractor])
        let otherBatch = try unwrap(store.getBatch(project: project))
        _ = try store.submit(batchID: otherBatch.id, proposals: [
            add(distractor, title: "家庭影院", body: "Jellyfin 播放电影时设置环绕音效和字幕。")
        ])
        let exact = try unwrap(store.search("APK v0.12.2", project: project).first)
        expectPresent(exact.keywordRank)
        let semantic = try unwrap(store.search("手机软件想在原位升级", project: project).first)
        expectEqual(semantic.id, exact.id)
        expectPresent(semantic.vector)
        expectTrue(try store.search("APK", project: unrelated.project).isEmpty)
        expectEqual(try store.history(exact.id).map(\.current.version), [1])
        expectEqual(try store.evidence(exact.memory.evidenceIDs).first?.id, first.id)
        try store.undo(batch.id)
        expectFalse(try store.search("APK", project: project).contains { $0.id == exact.id })
        expectEqual(try store.history(exact.id).map(\.current.version), [2, 1])
    }

    func testStaleUpdateDoesNotOverwriteAndRequeuesEvidence() throws {
        let store = try MemoryStore(path: ":memory:")
        let original = proof(1, text: "开发包版本保留签名 APK")
        try store.ingest([original])
        let initial = try unwrap(store.getBatch())
        _ = try store.submit(batchID: initial.id, proposals: [add(original, title: "APK 签名", body: "签名 APK 版本 1")])
        let updates = [proof(2, text: "更新签名 APK 版本 2"), proof(3, text: "更新签名 APK 版本 3")]
        try store.ingest(updates)
        let first = try unwrap(store.getBatch(limit: 1))
        let second = try unwrap(store.getBatch(limit: 1))
        let target = try unwrap(first.relatedMemories.first)
        func edit(_ evidence: Evidence, body: String) -> Proposal {
            .init(operation: .update, evidenceIDs: [evidence.id], reason: "用户纠正", scope: "project",
                  project: project, title: target.title, body: body, memoryID: target.id, expectedVersion: target.version)
        }
        _ = try store.submit(batchID: first.id, proposals: [edit(updates[0], body: "签名 APK 版本 2")])
        let conflicting = try store.submit(batchID: second.id, proposals: [edit(updates[1], body: "签名 APK 版本 3")])
        expectEqual(conflicting.decisions.first?.status, "conflict")
        expectEqual(try store.search("APK").first?.memory.body, "签名 APK 版本 2")
        expectEqual(try store.getBatch()?.evidence.map(\.id), [updates[1].id])
        expectError(try store.undo(initial.id))
        let summaries = try store.dreamBatchSummaries()
        expectEqual(summaries.first { $0.batchID == second.id }?.conflictCount, 1)
        expectEqual(summaries.first { $0.batchID == initial.id }?.canRollback, false)
    }

    func testScopeAndExclusionAreValidated() throws {
        let store = try MemoryStore(path: ":memory:")
        let source = proof(1, text: "我在所有项目使用同一套发布流程。")
        expectEqual(try store.ingest([source, proof(2, text: "api_key: example-secret-abcdef")]), 1)
        let batch = try unwrap(store.getBatch())
        let global = Proposal(operation: .add, evidenceIDs: [source.id], reason: "适用于所有项目",
                              scope: "global", title: "发布流程", body: "项目发布前统一检查版本。")
        expectEqual(try store.submit(batchID: batch.id, proposals: [global]).decisions.first?.status, "review")
        expectTrue(try store.search("").isEmpty)
        let review = try unwrap(store.dashboard().decisions.first)
        try store.review(review.id, accept: true)
        expectEqual(try store.search("", project: "/tmp/other").first?.memory.scope, "global")
        let excluded = proof(3, text: "临时项目记录")
        _ = try store.ingest([excluded])
        let pending = try unwrap(store.getBatch())
        try store.exclude(excluded, project: false)
        expectError(try store.getBatch(batchID: pending.id))
        expectError(try store.submit(batchID: pending.id, proposals: [add(excluded, title: "发布", body: "项目记录")]))
        expectEqual(try store.ingest([excluded]), 0)
    }

    func testCodexEvidenceUsesFinalOutputAndSkipsDreams() {
        let user: [String: Any] = ["type": "userMessage", "content": [["type": "text", "text": "以后测试包要签名。"]]]
        let final: [String: Any] = ["type": "agentMessage", "phase": "final_answer", "text": "已确认。"]
        let commentary: [String: Any] = ["type": "agentMessage", "phase": "commentary", "text": "分析草稿"]
        let tool: [String: Any] = ["type": "mcpToolCall", "tool": "dream_get_batch"]
        let turn: [String: Any] = ["status": "completed", "id": "t1", "items": [user, commentary, final]]
        let item = CodexSource.evidence(turn: turn, threadID: "c1", project: project, timestamp: 1)
        expectEqual(item?.id, "codex:c1:t1")
        expectTrue(item?.excerpt.contains("已确认") == true)
        expectFalse(item?.excerpt.contains("分析草稿") == true)
        var dream = turn
        dream["items"] = [user, tool, final]
        expectNil(CodexSource.evidence(turn: dream, threadID: "c1", project: project, timestamp: 1))
    }

    func testCodexScanCheckpointAndDeduplication() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appendingPathComponent("fixture")
        let now = Int(Date().timeIntervalSince1970)
        let fixture = """
            #!/bin/sh
            while IFS= read -r line; do
                case "$line" in
                    *thread*turns*list*) printf '%s\\n' '{"id":3,"result":{"data":[{"id":"new","status":"completed","completedAt":\(now),"items":[{"type":"userMessage","content":[{"type":"text","text":"新测试记录"}]}]},{"id":"old","status":"completed","completedAt":5,"items":[{"type":"userMessage","content":[{"type":"text","text":"启用前的旧记录"}]}]}],"nextCursor":null}}' ;;
                    *thread*list*) printf '%s\\n' '{"id":2,"result":{"data":[{"id":"fixture","cwd":"/tmp/fixture","updatedAt":\(now)}],"nextCursor":null}}' ;;
                    *initialized*) ;;
                    *initialize*) printf '%s\\n' '{"id":1,"result":{}}' ;;
                esac
            done
            """
        try fixture.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let dbPath = folder.appendingPathComponent("db").path
        let store = try MemoryStore(path: dbPath)
        try store.configureCapture(enabled: true, resetTo: Double(now - 10))
        expectEqual(try CodexSource.scan(store: store, executable: executable).inserted, 1)
        let restarted = try MemoryStore(path: dbPath)
        let savedScan = try unwrap(restarted.recentActivities().first)
        expectEqual(savedScan.kind, .scan)
        expectEqual(savedScan.agent, .codex)
        expectEqual(savedScan.count, 1)
        expectEqual(try CodexSource.scan(store: restarted, executable: executable).inserted, 0)
        expectEqual(try restarted.dashboard().evidence.map(\.turnID), ["new"])
    }

    func testMCPWritesViaSocket() throws {
        let temp = URL(fileURLWithPath: "/tmp/am-" + String(UUID().uuidString.prefix(10)))
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temp) }
        let socket = temp.appendingPathComponent("mcp.sock")
        let store = try MemoryStore(path: temp.appendingPathComponent("db").path)
        let server = try LocalToolServer(store: store, path: socket)
        try withExtendedLifetime(server) {
            let source = proof(1, text: "发布 APK 前测试。")
            try store.ingest([source])
            let request = try Wire.data(["name": "dream_get_batch"])
            let batch = try Wire.decode(DreamBatch.self, LocalConnection.call(request, socket: socket))
            let proposal = add(source, title: "APK 发布", body: "发布 APK 前执行测试。")
            struct Arguments: Encodable { let batchID: String; let proposals: [Proposal] }
            struct Request: Encodable { let name: String; let arguments: Arguments }
            let submitted = try Wire.data(Request(name: "dream_submit",
                                                  arguments: .init(batchID: batch.id, proposals: [proposal])))
            let result = try Wire.decode(Submission.self, LocalConnection.call(submitted, socket: socket))
            expectEqual(result.decisions.first?.status, "applied")
            expectEqual(try store.search("APK").first?.memory.title, "APK 发布")
        }
    }

    func testBulkDreamSnapshot() throws {
        let store = try MemoryStore(path: ":memory:")
        expectNil(try store.dashboard().queuedThrough)
        try store.ingest((1...10).map { proof($0, text: "待处理记录 \($0)") })
        let through = try unwrap(store.dashboard().queuedThrough)
        let url = try unwrap(CodexSource.batchDreamURL(through: through))
        let components = try unwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        expectEqual(components.scheme, "codex")
        expectEqual(components.host, "threads")
        expectEqual(components.path, "/new")
        let prompt = try unwrap(components.queryItems?.first(where: { $0.name == "prompt" })?.value)
        expectTrue(prompt.contains("through: \(through)"))
        let turn: [String: Any] = [
            "status": "completed", "id": "bulk-dream", "items": [
                ["type": "userMessage", "content": [["type": "text", "text": prompt]]]
            ]
        ]
        expectNil(CodexSource.evidence(turn: turn, threadID: "fixture", project: project, timestamp: 900))

        // A later import may contain an older conversation timestamp.
        let later = proof(0, text: "点击之后回填的较早记录")
        try store.ingest([later])
        let claim = Data("""
            {"name":"dream_get_batch","arguments":{"limit":8,"through":\(through)}}
            """.utf8)
        for expected in [8, 2] {
            let batch = try Wire.decode(DreamBatch.self, MCPTools.handle(claim, store: store))
            expectEqual(batch.evidence.count, expected)
            expectFalse(batch.evidence.contains { $0.id == later.id })
            _ = try store.submit(batchID: batch.id, proposals: [
                Proposal(operation: .skip, evidenceIDs: batch.evidence.map(\.id), reason: "临时测试记录")
            ])
        }
        let empty = try Wire.decode([String: String].self, MCPTools.handle(claim, store: store))
        expectEqual(empty["status"], "empty")
        expectEqual(try store.dashboard().evidence.map(\.id), [later.id])
    }

    func testLargeMCPBatch() throws {
        let temp = URL(fileURLWithPath: "/tmp/am-" + String(UUID().uuidString.prefix(10)))
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temp) }
        let socket = temp.appendingPathComponent("mcp.sock")
        let store = try MemoryStore(path: ":memory:")
        let excerpt = String(repeating: "批量做梦测试记录", count: 260)
        try store.ingest((1...8).map { proof($0, text: excerpt) })
        let server = try LocalToolServer(store: store, path: socket)
        try withExtendedLifetime(server) {
            let request = Data(#"{"name":"dream_get_batch","arguments":{"limit":8}}"#.utf8)
            let response = try LocalConnection.call(request, socket: socket)
            expectTrue(response.count > 32_768)
            let batch = try Wire.decode(DreamBatch.self, response)
            expectEqual(batch.evidence.count, 8)
            expectTrue(batch.evidence.allSatisfy { $0.excerpt == excerpt })
        }
    }

    func testGuidedRecall() throws {
        let temp = URL(fileURLWithPath: "/tmp/am-" + String(UUID().uuidString.prefix(10)))
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temp) }
        let socket = temp.appendingPathComponent("mcp.sock")
        let bridge = temp.appendingPathComponent("A 'quoted'.app/agent-memory-mcp")
        let hooks = temp.appendingPathComponent("hooks.json")
        let original = Data(#"{"description":"Existing","hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"/usr/bin/true"}]}],"Stop":[{"hooks":[{"type":"command","command":"/usr/bin/true"}]}]}}"#.utf8)
        try original.write(to: hooks)
        try CodexSetup.installHook(bridge: bridge, home: temp)
        let first = try Data(contentsOf: hooks)
        try CodexSetup.installHook(bridge: bridge, home: temp)
        expectEqual(try Data(contentsOf: hooks), first)
        expectTrue(try CodexSetup.hookInstalled(bridge: bridge, home: temp))
        try CodexSetup.removeHook(bridge: bridge, home: temp)
        expectFalse(try CodexSetup.hookInstalled(bridge: bridge, home: temp))
        let actual = try unwrap(JSONSerialization.jsonObject(with: Data(contentsOf: hooks)) as? NSDictionary)
        let expected = try unwrap(JSONSerialization.jsonObject(with: original) as? NSDictionary)
        expectTrue(actual == expected)

        let store = try MemoryStore(path: ":memory:")
        let evidence = proof(1, text: "Android release APK 需要项目签名。")
        try store.ingest([evidence])
        let batch = try unwrap(store.getBatch())
        _ = try store.submit(batchID: batch.id, proposals: [add(evidence, title: "Android release APK",
                                                        body: "用项目签名以便覆盖安装。")])
        let server = try LocalToolServer(store: store, path: socket)
        try withExtendedLifetime(server) {
            func hook(_ prompt: String, cwd: String) throws -> Data? {
                let data = try Wire.data(["prompt": prompt, "cwd": cwd, "session_id": "sample"])
                return try RecallHook.output(for: data, socket: socket)
            }
            let query = "Android release APK 怎么打包"
            expectNil(try hook(query, cwd: project))
            try CodexSetup.setRecall(true, socket: socket)
            let context = try unwrap(hook(query, cwd: project))
            expectTrue(String(decoding: context, as: UTF8.self).contains("UserPromptSubmit"))
            expectTrue(String(decoding: context, as: UTF8.self).contains("Android release APK"))
            expectNil(try hook(query, cwd: "/tmp/other-agent-memory-project"))
            expectNil(try hook("/quit", cwd: project))
            expectPresent(try hook(CodexSetup.testPrompt, cwd: project))
            expectPresent(try store.setting("recallVerifiedAt"))
            try CodexSetup.setRecall(false, socket: socket)
            expectNil(try hook(query, cwd: project))
            expectNil(try store.setting("recallVerifiedAt"))
        }
    }

    func testAntigravityMCPSetup() throws {
        let temp = URL(fileURLWithPath: "/tmp/am-" + String(UUID().uuidString.prefix(10)))
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temp) }
        let configDir = temp.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let configPath = configDir.appendingPathComponent("mcp_config.json")
        let original = Data(#"{"extra":1,"mcpServers":{"sqlite-helper":{"command":"sqlite-mcp-server","args":["/tmp/demo.db"]}}}"#.utf8)
        try original.write(to: configPath)

        let bridge = temp.appendingPathComponent("agent-memory-mcp")
        let fixture = """
            #!/bin/sh
            while IFS= read -r line; do
                case "$line" in
                    *tools/list*) printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"memory_search"},{"name":"dream_get_batch"},{"name":"dream_submit"}]}}' ;;
                    *initialize*) printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-11-25","capabilities":{}}}' ;;
                esac
            done
            """
        try fixture.write(to: bridge, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bridge.path)

        expectFalse(try AntigravitySetup.registration(bridge: bridge, configDir: configDir))
        try AntigravitySetup.connect(bridge: bridge, configDir: configDir)
        let first = try Data(contentsOf: configPath)
        try AntigravitySetup.connect(bridge: bridge, configDir: configDir)
        expectEqual(try Data(contentsOf: configPath), first)
        expectTrue(try AntigravitySetup.registration(bridge: bridge, configDir: configDir))

        let backups = try FileManager.default.contentsOfDirectory(atPath: configDir.path)
            .filter { $0.hasPrefix("mcp_config.agent-memory-backup-") }
        expectEqual(backups.count, 1)

        let otherBridge = temp.appendingPathComponent("other-mcp")
        expectError(try AntigravitySetup.registration(bridge: otherBridge, configDir: configDir))

        let socket = temp.appendingPathComponent("mcp.sock")
        let store = try MemoryStore(path: ":memory:")
        let sample = proof(1, text: "Antigravity 共享记忆验证样本。")
        try store.ingest([sample])
        let batch = try unwrap(store.getBatch())
        _ = try store.submit(batchID: batch.id, proposals: [add(sample, title: "共享记忆样本", body: "跨 Agent 可检索。")])
        let server = try LocalToolServer(store: store, path: socket)
        try withExtendedLifetime(server) {
            let status = try AntigravitySetup.verify(bridge: bridge, socket: socket, configDir: configDir)
            expectTrue(status.registered)
            expectTrue(status.toolsAvailable)
            expectNil(try store.setting("antigravityVerifiedAt"))
            let verifyRequest = try JSONSerialization.data(withJSONObject: [
                "name": "memory_search",
                "arguments": ["query": AntigravitySetup.verifyQuery]
            ])
            let response = try LocalConnection.call(verifyRequest, socket: socket)
            expectTrue(String(decoding: response, as: UTF8.self).contains("共享记忆样本"))
            expectPresent(try store.setting("antigravityVerifiedAt"))
        }

        try AntigravitySetup.disconnect(bridge: bridge, configDir: configDir)
        expectFalse(try AntigravitySetup.registration(bridge: bridge, configDir: configDir))
        let actual = try unwrap(JSONSerialization.jsonObject(with: Data(contentsOf: configPath)) as? NSDictionary)
        let expected = try unwrap(JSONSerialization.jsonObject(with: original) as? NSDictionary)
        expectTrue(actual == expected)
    }

    func testAntigravityRecallAndCapture() throws {
        let temp = URL(fileURLWithPath: "/tmp/am-" + String(UUID().uuidString.prefix(10)))
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temp) }

        let configDir = temp.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let hooksPath = configDir.appendingPathComponent("hooks.json")
        let originalHooks = Data(#"{"lint":{"PostToolUse":[{"matcher":"run_command","hooks":[{"type":"command","command":"./lint.sh"}]}]}}"#.utf8)
        try originalHooks.write(to: hooksPath)

        let bridge = temp.appendingPathComponent("A 'quoted'.app/agent-memory-mcp")
        try AntigravitySetup.installHook(bridge: bridge, configDir: configDir)
        let firstHooks = try Data(contentsOf: hooksPath)
        try AntigravitySetup.installHook(bridge: bridge, configDir: configDir)
        expectEqual(try Data(contentsOf: hooksPath), firstHooks)
        expectTrue(try AntigravitySetup.hookInstalled(bridge: bridge, configDir: configDir))
        try AntigravitySetup.removeHook(bridge: bridge, configDir: configDir)
        expectFalse(try AntigravitySetup.hookInstalled(bridge: bridge, configDir: configDir))
        let restored = try unwrap(JSONSerialization.jsonObject(with: Data(contentsOf: hooksPath)) as? NSDictionary)
        let expectedHooks = try unwrap(JSONSerialization.jsonObject(with: originalHooks) as? NSDictionary)
        expectTrue(restored == expectedHooks)

        let socket = temp.appendingPathComponent("mcp.sock")
        let store = try MemoryStore(path: ":memory:")
        let sample = proof(1, text: "Android release APK 需要项目签名。")
        try store.ingest([sample])
        let batch = try unwrap(store.getBatch())
        _ = try store.submit(batchID: batch.id, proposals: [add(sample, title: "Android release APK",
                                                                body: "用项目签名以便覆盖安装。")])
        let server = try LocalToolServer(store: store, path: socket)
        try withExtendedLifetime(server) {
            func hook(_ prompt: String, cwd: String, conversationId: String = "conv-1") throws -> String {
                let data = try Wire.data([
                    "cwd": cwd,
                    "lastUserInput": prompt,
                    "conversationId": conversationId,
                    "hookEventName": "PreInvocation"
                ])
                return String(decoding: try RecallHook.antigravityOutput(for: data, socket: socket), as: UTF8.self)
            }

            let query = "Android release APK 怎么打包"
            expectEqual(try hook(query, cwd: project), "{}")
            try AntigravitySetup.setRecall(true, socket: socket)

            let injected = try hook(query, cwd: project)
            expectTrue(injected.contains("injectSteps"))
            expectTrue(injected.contains("Android release APK"))
            // Duplicate PreInvocation within the same turn should not re-inject.
            expectEqual(try hook(query, cwd: project), "{}")
            expectEqual(try hook("Android release APK 如何签名", cwd: project), "{}")
            expectEqual(try hook("好的！", cwd: project, conversationId: "conv-short"), "{}")
            expectEqual(try store.setting("antigravityProject:conv-short"), ProjectIdentity.resolve(project))
            expectEqual(try store.todayRecallTotals().count, 1)
            expectEqual(try hook(query, cwd: "/tmp/other-project", conversationId: "conv-2"), "{}")
            try store.configureRecallCrossProject(true)
            let crossProject = try hook(query, cwd: "/tmp/other-project", conversationId: "conv-2")
            expectTrue(crossProject.contains("injectSteps"))
            expectTrue(crossProject.contains("Android release APK"))
            try store.configureRecallCrossProject(false)
            expectEqual(try hook(query, cwd: "/tmp/other-project", conversationId: "conv-3"), "{}")

            let verified = try hook(AntigravitySetup.testPrompt, cwd: project)
            expectTrue(verified.contains("injectSteps"))
            expectPresent(try store.setting("antigravityRecallVerifiedAt"))
            expectEqual(try store.setting("antigravityProject:conv-1"), ProjectIdentity.resolve(project))

            try AntigravitySetup.setRecall(false, socket: socket)
            expectEqual(try hook(query, cwd: project), "{}")
            expectNil(try store.setting("antigravityRecallVerifiedAt"))
        }

        // Verify Antigravity transcript scanning & filtering.
        let brainDir = temp.appendingPathComponent("brain", isDirectory: true)
        let convLogs = brainDir.appendingPathComponent("conv-1/.system_generated/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: convLogs, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        let nowISO = formatter.string(from: Date())
        let transcript = """
            {"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"\(nowISO)","content":"<USER_REQUEST>\\n以后发布前必须跑冒烟测试。\\n</USER_REQUEST>"}
            {"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"\(nowISO)","content":"已确认，发布前会先运行冒烟测试。"}
            {"step_index":2,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"\(nowISO)","content":"<USER_REQUEST>\\n帮我整理一下记忆\\n</USER_REQUEST>"}
            {"step_index":3,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"\(nowISO)","tool_calls":[{"name":"call_mcp_tool","args":{"ToolName":"dream_get_batch"}}]}
            {"step_index":4,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"\(nowISO)","content":"已提交做梦结果。"}
            {"step_index":5,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"\(nowISO)","content":"<USER_REQUEST>\\n\(AntigravitySetup.testPrompt)\\n</USER_REQUEST>"}
            {"step_index":6,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"\(nowISO)","content":"验证完成。"}
            """
        try transcript.write(to: convLogs.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8)
        try store.configureCapture(enabled: true, resetTo: Date().timeIntervalSince1970 - 60,
                                   enabledKey: AntigravitySource.enabledKey, cursorKey: AntigravitySource.cursorKey)
        let firstScan = try AntigravitySource.scan(store: store, brainDirectories: [brainDir])
        expectEqual(firstScan.scannedThreads, 1)
        expectEqual(firstScan.inserted, 1)
        let scanEvent = try unwrap(store.recentActivities().first)
        expectEqual(scanEvent.kind, .scan)
        expectEqual(scanEvent.agent, .antigravity)
        expectEqual(scanEvent.count, 1)
        let secondScan = try AntigravitySource.scan(store: store, brainDirectories: [brainDir])
        expectEqual(secondScan.inserted, 0)
        expectTrue(try store.dashboard().evidence.contains { $0.id == "antigravity:conv-1:0" })
    }

    func testRecallVersionsAndActivityLog() throws {
        let folder = URL(fileURLWithPath: "/tmp/am-" + String(UUID().uuidString.prefix(10)))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let socket = folder.appendingPathComponent("mcp.sock")
        let path = folder.appendingPathComponent("db").path
        let store = try MemoryStore(path: path)
        let server = try LocalToolServer(store: store, path: socket)
        try withExtendedLifetime(server) {
            let evidence = proof(1, text: "Android release APK 使用项目签名。")
            try store.ingest([evidence])
            let batch = try unwrap(store.getBatch(project: project))
            let proposal = add(evidence, title: "Android release APK", body: "使用项目签名。")
            _ = try store.submit(batchID: batch.id, proposals: [proposal])
            _ = try store.submit(batchID: batch.id, proposals: [proposal])
            let memoryID = try unwrap(store.search("Android release APK", project: project).first?.id)

            func hook(_ prompt: String, session: String = "shared-session", socket target: URL = socket) throws -> String? {
                let input = try Wire.data(["prompt": prompt, "cwd": project, "session_id": session])
                return try RecallHook.output(for: input, socket: target).map { String(decoding: $0, as: UTF8.self) }
            }

            let unreachable = folder.appendingPathComponent("absent.sock")
            for short in ["好的！", "继续。", "  OK!! ", "谢谢", "Thank you.", "👍"] {
                expectNil(try hook(short, socket: unreachable))
            }
            let query = "Android release APK 怎么打包"
            let newPrompt = "Android release APK 怎么签名"
            try CodexSetup.setRecall(true, socket: socket)
            let codexContext = try unwrap(hook(query))
            expectTrue(codexContext.contains("用户本轮要求优先"))
            expectPresent(codexContext.range(of: #"\[\d{4}-\d{2}-\d{2}\]"#, options: .regularExpression))
            expectNil(try hook(newPrompt))
            expectPresent(try hook(query, session: "another-session"))

            // An identical thread ID from another host has its own recall state.
            try AntigravitySetup.setRecall(true, socket: socket)
            let antigravityInput = try Wire.data(["lastUserInput": query, "cwd": project, "conversationId": "shared-session"])
            let antigravity = try RecallHook.antigravityOutput(for: antigravityInput, socket: socket)
            expectTrue(String(decoding: antigravity, as: UTF8.self).contains("injectSteps"))

            let update = proof(2, text: "Android release APK 改用新版签名。")
            try store.ingest([update])
            let editBatch = try unwrap(store.getBatch(project: project))
            let edit = Proposal(operation: .update, evidenceIDs: [update.id], reason: "用户纠正", scope: "project",
                                project: project, title: "Android release APK", body: "改用新版签名。",
                                memoryID: memoryID, expectedVersion: 1)
            _ = try store.submit(batchID: editBatch.id, proposals: [edit])
            expectTrue(try unwrap(hook(newPrompt)).contains("改用新版签名"))
            for turn in 1...12 {
                expectNil(try hook("Android release APK 如何发布 第 \(turn) 轮"))
            }
            expectPresent(try hook("Android release APK 如何发布 第 13 轮"))
            try store.undo(editBatch.id)

            let badRequest = try Wire.data(["name": "unknown_tool"])
            let badResult = try LocalConnection.call(badRequest, socket: socket)
            expectTrue(String(decoding: badResult, as: UTF8.self).contains("toolError"))

            let reopened = try MemoryStore(path: path)
            let events = try reopened.recentActivities()
            expectEqual(try reopened.recentActivities(limit: 1).map(\.kind), [.error])
            expectEqual(events.filter { $0.kind == .dreamClaim }.map(\.batchID), [editBatch.id, batch.id])
            expectEqual(events.filter { $0.kind == .dreamSubmit }.map(\.batchID), [editBatch.id, batch.id])
            expectEqual(events.filter { $0.kind == .dreamRollback }.map(\.batchID), [editBatch.id])
            expectEqual(events.filter { $0.kind == .search }.map(\.count), [1])
            let recalls = events.filter { $0.kind == .recall }
            expectEqual(recalls.map(\.agent), [.codex, .codex, .antigravity, .codex, .codex])
            for event in recalls {
                expectEqual(event.memoryIDs, [memoryID])
                expectEqual(event.project, ProjectIdentity.resolve(project))
                expectEqual(event.count, 1)
                expectTrue((event.estimatedTokens ?? 0) > 0)
            }
            let totals = try reopened.todayRecallTotals()
            expectEqual(totals.count, recalls.count)
            expectEqual(totals.estimatedTokens, recalls.compactMap(\.estimatedTokens).reduce(0, +))
            let memory = try unwrap(reopened.memory(id: memoryID))
            expectEqual(memory.hitCount, 5)
            expectPresent(memory.lastHitAt)
            expectEqual(memory.version, 3)
        }
    }

    func testRecallIgnoresGenericQuestionsAndFindsSpecificMemories() throws {
        let store = try MemoryStore(path: ":memory:")
        try store.setSetting("recallEnabled", "1")
        try seedMemories([
            ("窗口使用习惯", "目前没有窗口可以继续使用，状态在设置里查看。"),
            ("直连丢包", "直连丢包时切换中继。"),
            ("省电模式 FSEvents", "文件变动触发扫描，合并事件后再启动采集。")
        ], in: store)

        let genericQuery = "两边要新开窗口还是继续在原有会话窗口使用？"
        expectTrue(try store.search(genericQuery).contains { $0.memory.title == "窗口使用习惯" })
        expectEqual(try recall(genericQuery, store: store), "")
        expectEqual(try store.todayRecallTotals().count, 0)

        let networkContext = try recall("直连丢包", store: store)
        expectTrue(networkContext.contains("直连丢包"))
        expectFalse(networkContext.contains("省电模式 FSEvents"))
        let captureContext = try recall("省电模式 FSEvents", store: store)
        expectTrue(captureContext.contains("省电模式 FSEvents"))
        expectFalse(captureContext.contains("直连丢包"))
        expectEqual(try store.todayRecallTotals().count, 2)
    }

    func testRecallVectorThresholdsAndKeywordFallback() throws {
        try withRecallDatabase { store, path in
            let anchorTitle = "FSEvents /tmp/cache.db v0.12.2 窗口可以继续使用"
            let anchorBody = "continue using current window 链路 刷新 直连 丢包 采集 扫描 内存 缓存"
            let query = anchorTitle + "\n" + anchorBody
            let samples: [(title: String, body: String, similarity: Float?, admitted: Bool)] = [
                ("低分否决", "FSEvents 链路 直连 丢包", 0.31, false),
                ("低于混合门槛", "FSEvents 链路 直连 丢包", 0.49, false),
                ("纯语义命中", "事件驱动调度", 0.63, true),
                ("单个技术词", "监测 FSEvents 信号", 0.51, true),
                ("两个中文词", "直连 丢包", 0.51, true),
                ("单个中文词", "显示链路延迟", 0.61, false),
                ("泛化词重叠", "窗口可以继续使用 continue using current window", 0.56, false),
                ("完整路径", "读取 /tmp/cache.db", 0.51, true),
                ("完整版本", "兼容 v0.12.2", 0.51, true),
                ("路径和版本的片段", "写入 /tmp/other.db，适配 v0.12.3", 0.56, false),
                ("三词降级", "FSEvents 直连 丢包", nil, true),
                ("比例降级", "FSEvents 文件监听", nil, false)
            ]
            let anchorProject = "/tmp/am-vector-anchor"
            try seedMemories([(anchorTitle, anchorBody)], in: store, project: anchorProject)
            try seedMemories(samples.map { ($0.title, $0.body) }, in: store)
            let anchor = try unwrap(store.inspectSearch("", scope: .project(anchorProject)).hits.first)
            let base = try storedVector(for: anchor.id, path: path)
            let memories = try store.inspectSearch("", scope: .project(project)).hits.map(\.memory)
            let byTitle = Dictionary(uniqueKeysWithValues: memories.map { ($0.title, $0.id) })
            for sample in samples {
                let id = try unwrap(byTitle[sample.title])
                if let similarity = sample.similarity {
                    try setSimilarity(similarity, relativeTo: base, memoryID: id, path: path)
                } else {
                    try executeSQLite("UPDATE memory SET vectors = NULL WHERE id = '\(id)'", path: path)
                }
            }

            let inspection = try store.inspectSearch(query, scope: .project(project), includeFilteredCandidates: true)
            expectEqual(Set(inspection.hits.map(\.memory.title)), Set(samples.filter(\.admitted).map(\.title)))
            expectEqual(Set(inspection.filteredCandidates.map(\.memory.title)),
                        Set(samples.filter { !$0.admitted }.map(\.title)))
            let vetoed = try unwrap(inspection.filteredCandidates.first { $0.memory.title == "低分否决" })
            expectPresent(vetoed.keywordRank)
            expectTrue(abs((vetoed.vector ?? 0) - 0.31) < 0.001)

            let manual = try JSONSerialization.data(withJSONObject: [
                "name": "memory_search", "arguments": ["query": query, "project": project]
            ])
            let response = try MCPTools.handle(manual, store: store)
            struct SearchResponse: Decodable { let hits: [SearchHit] }
            expectTrue(try Wire.decode(SearchResponse.self, response).hits.contains { $0.id == vetoed.id })

            // One of two effective terms passes the ratio fallback when the candidate has no vector.
            let fallback = try store.inspectSearch("FSEvents 直连", scope: .project(project))
            expectTrue(fallback.hits.contains { $0.memory.title == "比例降级" && $0.vector == nil })
        }
    }

    func testRecallDoesNotBackfillAfterDeduplication() throws {
        try withRecallDatabase { store, path in
            try seedMemories([
                ("FSEvents 扫描", "文件变化后防抖。"),
                ("FSEvents 省电", "空闲时减少进程唤醒。"),
                ("FSEvents 排错", "查看文件监听权限。"),
                ("FSEvents 测试", "用临时目录验证事件。")
            ], in: store)
            try executeSQLite("UPDATE memory SET vectors = NULL", path: path)
            let firstQuery = "FSEvents 怎么设置"
            let nextQuery = "FSEvents 如何使用"
            let firstRanking = try store.inspectSearch(firstQuery).hits
            expectEqual(firstRanking.count, 4)
            expectEqual(try store.inspectSearch(nextQuery).hits.map(\.id), firstRanking.map(\.id))

            let firstContext = try recall(firstQuery, store: store)
            for hit in firstRanking.prefix(3) { expectTrue(firstContext.contains(hit.memory.title)) }
            expectFalse(firstContext.contains(firstRanking[3].memory.title))
            expectEqual(try recall(nextQuery, store: store), "")
            expectEqual(try store.todayRecallTotals().count, 1)
            expectEqual(try store.memory(id: firstRanking[3].id)?.hitCount, 0)
        }
    }

    private func recall(_ query: String, store: MemoryStore) throws -> String {
        let request = try JSONSerialization.data(withJSONObject: ["name": "_recall_context", "arguments": [
            "query": query, "project": project, "threadID": "smoke-recall"
        ]])
        let response = try MCPTools.handle(request, store: store)
        return try unwrap(Wire.decode([String: String].self, response)["context"])
    }

    private func seedMemories(_ records: [(title: String, body: String)], in store: MemoryStore,
                              project: String? = nil) throws {
        let scope = project ?? self.project
        let evidence = records.enumerated().map { index, record in
            Evidence(id: UUID().uuidString, threadID: "seed-\(index)", turnID: "seed-\(index)",
                     project: scope, timestamp: Double(index), excerpt: record.title + "\n" + record.body)
        }
        try store.ingest(evidence)
        let byID = Dictionary(uniqueKeysWithValues: zip(evidence.map(\.id), records))
        while let batch = try store.getBatch(project: scope, limit: 8) {
            let proposals = try batch.evidence.map { item in
                let record = try unwrap(byID[item.id])
                return add(item, title: record.title, body: record.body)
            }
            let result = try store.submit(batchID: batch.id, proposals: proposals)
            for decision in result.decisions where decision.status == "review" {
                try store.review(decision.id, accept: true)
            }
        }
    }

    private func withRecallDatabase(_ action: (MemoryStore, String) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("memory.sqlite3").path
        let store = try MemoryStore(path: path)
        try store.setSetting("recallEnabled", "1")
        try action(store, path)
    }

    func testLegacyMemoryStatisticsMigration() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("memory.sqlite3").path
        let first = proof(1, text: "Android 签名包按发布流水线交付。")
        let memoryID: String
        let batchID: String
        let expectedCreatedAt: Double
        do {
            let store = try MemoryStore(path: path)
            try store.ingest([first])
            let batch = try unwrap(store.getBatch())
            batchID = batch.id
            expectedCreatedAt = batch.expires - 1800
            _ = try store.submit(batchID: batch.id, proposals: [
                add(first, title: "Android 签名包", body: "Android 签名包按发布流水线交付。")
            ])
            memoryID = try unwrap(store.search("").first?.id)
        }
        // Restore the exact pre-Wave-2 columns and JSON shape before opening the old DB.
        try executeSQLite("""
            DROP TRIGGER vector_revision_insert;
            DROP TRIGGER vector_revision_update;
            DROP TRIGGER vector_revision_delete;
            DROP TABLE vector_revision;
            DROP INDEX memory_health_age;
            DROP INDEX decision_batch_status;
            DROP INDEX history_batch;
            ALTER TABLE memory DROP COLUMN hit_count;
            ALTER TABLE memory DROP COLUMN last_hit_at;
            ALTER TABLE memory DROP COLUMN content_version;
            ALTER TABLE batch DROP COLUMN created_at;
            UPDATE memory SET payload = CAST(json_remove(CAST(payload AS TEXT), '$.hitCount', '$.lastHitAt') AS BLOB);
            UPDATE history SET current = CAST(json_remove(CAST(current AS TEXT), '$.hitCount', '$.lastHitAt') AS BLOB);
            DELETE FROM grdb_migrations WHERE identifier = 'memory_health_and_inspection';
            """, path: path)
        let store = try MemoryStore(path: path)
        let migrated = try unwrap(store.memory(id: memoryID))
        expectEqual(migrated.hitCount, 0)
        expectNil(migrated.lastHitAt)
        expectEqual(try store.history(memoryID).first?.current.hitCount, 0)
        expectEqual(try store.dreamBatchSummaries().first?.batchID, batchID)
        expectEqual(try store.dreamBatchSummaries().first?.createdAt, expectedCreatedAt)
        expectEqual(try store.dreamBatchSummaries().first?.canRollback, true)

        _ = try store.inspectSearch("Android 签名包", includeFilteredCandidates: true)
        _ = try store.search("Android 签名包")
        expectEqual(try store.memory(id: memoryID)?.hitCount, 0)
        let revision = try querySQLite("SELECT revision FROM vector_revision", path: path)

        let request = try JSONSerialization.data(withJSONObject: [
            "name": "memory_search", "arguments": ["query": "Android 签名包", "project": project, "limit": 1]
        ])
        let before = Date().timeIntervalSince1970
        _ = try MCPTools.handle(request, store: store)
        _ = try MCPTools.handle(request, store: store)
        let reopened = try MemoryStore(path: path)
        let counted = try unwrap(reopened.memory(id: memoryID))
        expectEqual(counted.hitCount, 2)
        expectTrue((counted.lastHitAt ?? 0) >= before)
        expectEqual(counted.version, migrated.version)
        expectEqual(counted.updated, migrated.updated)
        expectEqual(try querySQLite("SELECT revision FROM vector_revision", path: path), revision)
    }

    func testVectorCacheInspectionAndMemoryHealth() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("memory.sqlite3").path
        let store = try MemoryStore(path: path)
        let other = "/tmp/am-other-project"
        let title = "Android release APK"
        let body = "Publish using the existing project signature"
        let query = title + "\n" + body
        let originals = [proof(1, text: query), proof(2, text: query, project: other)]
        let edgeEvidence = proof(3, text: "Orchid cultivar humidity tray")
        try store.ingest(originals + [edgeEvidence])
        for item in originals {
            let batch = try unwrap(store.getBatch(project: item.project, limit: 1))
            _ = try store.submit(batchID: batch.id, proposals: [add(item, title: title, body: body)])
        }
        let edgeBatch = try unwrap(store.getBatch(project: project))
        let proposedGlobal = Proposal(operation: .add, evidenceIDs: [edgeEvidence.id], reason: "通用偏好",
                                      scope: "global", title: "Orchid cultivar", body: "Humidity tray")
        let decision = try unwrap(store.submit(batchID: edgeBatch.id, proposals: [proposedGlobal]).decisions.first)
        try store.review(decision.id, accept: true)

        let first = try unwrap(store.inspectSearch(query, scope: .project(project)).hits.first)
        let second = try unwrap(store.inspectSearch(query, scope: .project(other)).hits.first)
        let edge = try unwrap(store.inspectSearch("", scope: .global).hits.first)
        expectTrue((first.vector ?? 0) > 0.99)
        let health = try store.memoryHealthSummary()
        expectEqual(health.activeCount, 3)
        expectEqual(health.archivedCount, 0)
        let pair = health.duplicatePairs.first { Set([$0.memoryAID, $0.memoryBID]) == Set([first.id, second.id]) }
        expectTrue((pair?.similarity ?? 0) > 0.99)

        let base = try storedVector(for: first.id, path: path)
        try setSimilarity(0.31, relativeTo: base, memoryID: edge.id, path: path)
        let aged = Date().timeIntervalSince1970 - 31 * 86_400
        try executeSQLite("UPDATE memory SET updated = \(aged) WHERE id = '\(second.id)'", path: path)
        let inspected = try store.inspectSearch(query, scope: .all, includeFilteredCandidates: true)
        expectEqual(Set(inspected.hits.map(\.id)), Set([first.id, second.id]))
        expectEqual(inspected.filteredCandidates.map(\.id), [edge.id])
        let edgeScore = try unwrap(inspected.filteredCandidates.first?.vector)
        expectTrue(abs(edgeScore - 0.31) < 0.001)
        expectTrue(inspected.elapsedMs >= 0)
        expectTrue(try store.inspectSearch(query, scope: .project(project), includeFilteredCandidates: true).filteredCandidates.isEmpty)
        expectTrue(try store.inspectSearch(query, scope: .global).filteredCandidates.isEmpty)
        expectEqual(try store.memoryHealthSummary().dormantMemoryIDs, [second.id])

        // Deliberately invalidate the vector in a different connection, then repair it.
        try executeSQLite("UPDATE memory SET vectors = NULL WHERE id = '\(first.id)'", path: path)
        expectNil(try store.inspectSearch(query, scope: .project(project)).hits.first?.vector)
        expectTrue(try store.repairVectors())
        expectTrue((try store.inspectSearch(query, scope: .project(project)).hits.first?.vector ?? 0) > 0.99)

        let updateEvidence = proof(4, text: query + " update deployment handling")
        try store.ingest([updateEvidence])
        let updateBatch = try unwrap(store.getBatch(project: project))
        let newBody = "Deployment uses a hardware-backed signing key"
        let edit = Proposal(operation: .update, evidenceIDs: [updateEvidence.id], reason: "用户更新部署流程",
                            scope: "project", project: project, title: title, body: newBody,
                            memoryID: first.id, expectedVersion: 1)
        let edited = try unwrap(store.submit(batchID: updateBatch.id, proposals: [edit]).decisions.first)
        expectEqual(edited.status, "applied")
        expectTrue((try store.inspectSearch(title + "\n" + newBody, scope: .project(project)).hits.first?.vector ?? 0) > 0.99)
        expectEqual(try store.memory(id: first.id, version: 1)?.body, body)

        let archiveEvidence = proof(5, text: title + "\n" + newBody)
        try store.ingest([archiveEvidence])
        let archiveBatch = try unwrap(store.getBatch(project: project))
        let archive = Proposal(operation: .archive, evidenceIDs: [archiveEvidence.id], reason: "用户要求归档",
                               memoryID: first.id, expectedVersion: 2)
        let pending = try unwrap(store.submit(batchID: archiveBatch.id, proposals: [archive]).decisions.first)
        try store.review(pending.id, accept: true)
        expectTrue(try store.inspectSearch(query, scope: .project(project)).hits.isEmpty)
        let archived = try store.memoryHealthSummary()
        expectEqual(archived.activeCount, 2)
        expectEqual(archived.archivedCount, 1)
        expectTrue(archived.duplicatePairs.isEmpty)
        try store.undo(archiveBatch.id)
        expectTrue((try store.inspectSearch(title + "\n" + newBody, scope: .project(project)).hits.first?.vector ?? 0) > 0.99)
        expectEqual(try store.memoryHealthSummary().activeCount, 3)
    }

    func testDreamBatchSummariesAndLookups() throws {
        let store = try MemoryStore(path: ":memory:")
        let first = proof(1, text: "Mac 打包使用签名。")
        let second = proof(2, text: "发布前验证备份。")
        try store.ingest([first, second])
        let batch = try unwrap(store.getBatch(project: project))
        expectTrue(try store.dreamBatchSummaries().isEmpty)
        let proposedGlobal = Proposal(operation: .add, evidenceIDs: [second.id], reason: "全局发布约定",
                                      scope: "global", title: "备份校验", body: "先验证备份再发布。")
        let result = try store.submit(batchID: batch.id, proposals: [
            add(first, title: "Mac 交付签名", body: "Mac 打包使用项目签名。"), proposedGlobal
        ])
        let summary = try unwrap(store.dashboard().batchSummaries.first)
        expectEqual(summary.batchID, batch.id)
        expectTrue(abs(summary.createdAt - (batch.expires - 1800)) < 0.001)
        expectEqual(summary.appliedCount, 1)
        expectEqual(summary.pendingCount, 1)
        expectEqual(summary.conflictCount, 0)
        expectTrue(summary.canRollback)
        expectEqual(try store.evidence([second.id, "missing", first.id, second.id]).map(\.id),
                    [second.id, first.id, second.id])
        expectNil(try store.memory(id: "missing"))

        let pending = try unwrap(result.decisions.first { $0.status == "review" })
        try store.review(pending.id, accept: true)
        expectEqual(try store.dreamBatchSummaries().first?.appliedCount, 2)
        expectEqual(try store.dreamBatchSummaries().first?.pendingCount, 0)
        let active = try unwrap(store.inspectSearch("", scope: .global).hits.first?.memory)
        expectEqual(try store.memory(id: active.id)?.body, active.body)
        try store.undo(batch.id)
        expectEqual(try store.dreamBatchSummaries().first?.canRollback, false)
        expectEqual(try store.memory(id: active.id)?.archived, true)
        expectEqual(try store.memory(id: active.id, version: 1)?.archived, false)
    }

    private struct StoredVector: Codable {
        let model: String
        let values: [Float]
    }

    private func storedVector(for memoryID: String, path: String) throws -> StoredVector {
        let json = try querySQLite("SELECT CAST(vectors AS TEXT) FROM memory WHERE id = '\(memoryID)'", path: path)
        return try unwrap(Wire.decode([StoredVector].self, Data(json.utf8)).first)
    }

    private func setSimilarity(_ similarity: Float, relativeTo base: StoredVector, memoryID: String,
                               path: String) throws {
        let axis = try unwrap(base.values.indices.min { abs(base.values[$0]) < abs(base.values[$1]) })
        let basis = base.values[axis]
        let orthogonalScale = sqrt(1 - similarity * similarity) / sqrt(1 - basis * basis)
        let values = base.values.enumerated().map { index, value in
            similarity * value + orthogonalScale * ((index == axis ? 1 : 0) - basis * value)
        }
        let data = try Wire.data([StoredVector(model: base.model, values: values)])
        let hex = data.map { String(format: "%02x", $0) }.joined()
        try executeSQLite("UPDATE memory SET vectors = X'\(hex)' WHERE id = '\(memoryID)'", path: path)
    }

    private func withSQLite<T>(path: String, _ action: (OpaquePointer) throws -> T) throws -> T {
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil)
        defer { if let handle { sqlite3_close(handle) } }
        guard status == SQLITE_OK, let handle else { throw MemoryError.invalid("无法打开 SQLite 烟测数据。") }
        sqlite3_busy_timeout(handle, 1000)
        return try action(handle)
    }

    private func executeSQLite(_ sql: String, path: String) throws {
        try withSQLite(path: path) { handle in
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
                throw MemoryError.invalid(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    private func querySQLite(_ sql: String, path: String) throws -> String {
        try withSQLite(path: path) { handle in
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else {
                throw MemoryError.invalid(String(cString: sqlite3_errmsg(handle)))
            }
            return String(cString: value)
        }
    }

    func testSmartCaptureAndIncrementalRead() throws {
        let store = try MemoryStore(path: ":memory:")
        expectTrue(try store.isSmartCaptureEnabled())
        try store.configureSmartCapture(false)
        expectFalse(try store.isSmartCaptureEnabled())
        try store.configureSmartCapture(true)
        expectTrue(try store.isSmartCaptureEnabled())

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("am-smart-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        // Codex activity precheck ignores config files and detects session writes.
        let codexHome = temp.appendingPathComponent("codex-home", isDirectory: true)
        let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let since = Date().timeIntervalSince1970 + 5
        try Data("{}".utf8).write(to: codexHome.appendingPathComponent("config.toml"))
        expectFalse(CodexSource.hasRecentActivity(since: since, codexHome: codexHome))
        let sessionFile = sessions.appendingPathComponent("rollout.jsonl")
        try Data("{\"type\":\"turn\"}\n".utf8).write(to: sessionFile)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: since + 1)], ofItemAtPath: sessionFile.path)
        expectTrue(CodexSource.hasRecentActivity(since: since, codexHome: codexHome))

        // Antigravity incremental byte-offset reading across an incomplete turn and a follow-up turn.
        let brainDir = temp.appendingPathComponent("brain", isDirectory: true)
        let convLogs = brainDir.appendingPathComponent("conv-inc/.system_generated/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: convLogs, withIntermediateDirectories: true)
        let transcriptURL = convLogs.appendingPathComponent("transcript.jsonl")
        let formatter = ISO8601DateFormatter()
        let nowISO = formatter.string(from: Date())

        let part1 = """
            {"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"\(nowISO)","content":"<USER_REQUEST>\\n项目路径是 @[/Users/demo/project-inc/README.md]，先记一下规范。\\n</USER_REQUEST>"}
            {"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"\(nowISO)","content":"收到，已记录第一条规范。"}
            {"step_index":2,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"\(nowISO)","content":"<USER_REQUEST>\\n第二轮正在思考中，还没回答完。\\n</USER_REQUEST>"}
            """ + "\n"
        try part1.write(to: transcriptURL, atomically: true, encoding: .utf8)
        try store.configureCapture(enabled: true, resetTo: Date().timeIntervalSince1970 - 60,
                                   enabledKey: AntigravitySource.enabledKey, cursorKey: AntigravitySource.cursorKey)

        let scan1 = try AntigravitySource.scan(store: store, brainDirectories: [brainDir])
        expectEqual(scan1.inserted, 1)
        expectPresent(try store.setting("antigravityOffset:conv-inc"))

        // Second scan with no file changes should skip cleanly without reading.
        let scan2 = try AntigravitySource.scan(store: store, brainDirectories: [brainDir])
        expectEqual(scan2.scannedThreads, 1)
        expectEqual(scan2.inserted, 0)

        // Append completion for turn 2 and a brand-new turn 3.
        let part2 = """
            {"step_index":3,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"\(nowISO)","content":"第二轮现在回答完成了。"}
            {"step_index":4,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"\(nowISO)","content":"<USER_REQUEST>\\n第三轮补充要求。\\n</USER_REQUEST>"}
            {"step_index":5,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"\(nowISO)","content":"第三轮也已完成。"}
            """ + "\n"
        let handle = try FileHandle(forWritingTo: transcriptURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(part2.utf8))
        try handle.close()

        let scan3 = try AntigravitySource.scan(store: store, brainDirectories: [brainDir])
        expectEqual(scan3.inserted, 2)
        let ids = Set(try store.dashboard().evidence.map(\.id))
        expectTrue(ids.contains("antigravity:conv-inc:0"))
        expectTrue(ids.contains("antigravity:conv-inc:2"))
        expectTrue(ids.contains("antigravity:conv-inc:4"))

        // Fourth scan with unchanged file should skip completely (0 scannedThreads).
        let scan4 = try AntigravitySource.scan(store: store, brainDirectories: [brainDir])
        expectEqual(scan4.scannedThreads, 0)
        expectEqual(scan4.inserted, 0)
    }
}

private func unwrap<T>(_ value: T?, line: UInt = #line) throws -> T {
    guard let value else { throw MemoryError.invalid("第 \(line) 行缺少预期值。") }
    return value
}

private func expectTrue(_ value: @autoclosure () throws -> Bool, line: UInt = #line) {
    do {
        let result = try value()
        precondition(result, "第 \(line) 行断言失败。")
    }
    catch { preconditionFailure("第 \(line) 行抛出错误：\(error)") }
}

private func expectFalse(_ value: @autoclosure () throws -> Bool, line: UInt = #line) {
    expectTrue(try !value(), line: line)
}

private func expectEqual<T: Equatable>(_ actual: @autoclosure () throws -> T, _ expected: T, line: UInt = #line) {
    do {
        let value = try actual()
        precondition(value == expected, "第 \(line) 行：\(value) != \(expected)")
    } catch { preconditionFailure("第 \(line) 行抛出错误：\(error)") }
}

private func expectPresent<T>(_ value: T?, line: UInt = #line) { expectTrue(value != nil, line: line) }
private func expectNil<T>(_ value: T?, line: UInt = #line) { expectTrue(value == nil, line: line) }

private func expectError<T>(_ action: @autoclosure () throws -> T, line: UInt = #line) {
    do {
        _ = try action()
        preconditionFailure("第 \(line) 行应抛出错误。")
    } catch {}
}
