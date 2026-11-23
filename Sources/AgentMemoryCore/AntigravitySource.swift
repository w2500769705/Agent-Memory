import Foundation

public enum AntigravitySource {
    public static let enabledKey = "antigravityEnabled"
    public static let cursorKey = "antigravityScanSince"
    private static let batchDreamPrefix = "Agent Memory · 批量做梦"

    public static var defaultBrainDirectories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".gemini/antigravity/brain", isDirectory: true),
            home.appendingPathComponent(".gemini/antigravity-cli/brain", isDirectory: true),
            home.appendingPathComponent(".gemini/antigravity-ide/brain", isDirectory: true)
        ]
    }

    public static func scan(store: MemoryStore, brainDirectories: [URL]? = nil) throws -> ScanResult {
        do {
            return try scanEnabled(store: store, brainDirectories: brainDirectories)
        } catch {
            store.recordError(error, operation: "采集失败", agent: .antigravity)
            throw error
        }
    }

    private static func scanEnabled(store: MemoryStore, brainDirectories: [URL]?) throws -> ScanResult {
        guard try store.setting(enabledKey) == "1",
              let raw = try store.setting(cursorKey),
              let since = Double(raw) else {
            return ScanResult(inserted: 0, skippedThreads: 0, scannedThreads: 0)
        }
        let checkpoint = Date().timeIntervalSince1970
        let projects = Set((try store.setting("excludedProjects") ?? "").split(separator: "\n").map(String.init))
        let threads = Set((try store.setting("excludedThreads") ?? "").split(separator: "\n").map(String.init))
        let fileManager = FileManager.default
        let roots = brainDirectories ?? defaultBrainDirectories

        var evidence: [Evidence] = []
        var scanned = 0
        var skipped = 0

        for root in roots {
            guard let conversations = try? fileManager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            ) else { continue }

            for dir in conversations {
                guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                let conversationID = dir.lastPathComponent
                guard !threads.contains(conversationID) else { continue }
                let transcript = dir.appendingPathComponent(".system_generated/logs/transcript.jsonl")
                guard fileManager.fileExists(atPath: transcript.path) else { continue }
                let resourceValues = try? transcript.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                if let mtime = resourceValues?.contentModificationDate,
                   mtime.timeIntervalSince1970 < since - 2 {
                    continue
                }
                let fileSize = UInt64(max(0, resourceValues?.fileSize ?? 0))
                let recordedProject = try store.setting("antigravityProject:\(conversationID)")
                let cachedOffset = parseOffsetSetting(try store.setting("antigravityOffset:\(conversationID)"))

                if let cached = cachedOffset,
                   recordedProject != nil,
                   cached.fileSize == fileSize,
                   cached.resumeOffset == fileSize {
                    continue
                }

                let startOffset: UInt64
                if let cached = cachedOffset,
                   recordedProject != nil,
                   cached.resumeOffset <= fileSize {
                    startOffset = cached.resumeOffset
                } else {
                    startOffset = 0
                }

                guard let chunk = readChunk(from: transcript, startingAt: startOffset) else {
                    skipped += 1
                    continue
                }
                let parsed = parseTranscriptData(
                    chunk,
                    baseOffset: startOffset,
                    conversationID: conversationID,
                    recordedProject: recordedProject,
                    since: since
                )
                guard let project = parsed.project, !project.isEmpty else {
                    if !parsed.evidence.isEmpty { skipped += 1 }
                    continue
                }
                if recordedProject == nil {
                    try? store.setSetting("antigravityProject:\(conversationID)", project)
                }
                try? store.setSetting("antigravityOffset:\(conversationID)", "\(parsed.nextResumeOffset):\(fileSize)")
                guard !projects.contains(project) else { continue }
                scanned += 1
                evidence += parsed.evidence
            }
        }

        let next = skipped > 0 ? since : max(since, checkpoint - 120)
        let count = try store.ingest(evidence, scannedFrom: since, checkpoint: next,
                                     enabledKey: enabledKey, cursorKey: cursorKey,
                                     scanAgent: scanned > 0 || skipped > 0 ? .antigravity : nil)
        return ScanResult(inserted: count, skippedThreads: skipped, scannedThreads: scanned)
    }

    private static func parseOffsetSetting(_ raw: String?) -> (resumeOffset: UInt64, fileSize: UInt64)? {
        guard let raw else { return nil }
        let parts = raw.split(separator: ":")
        guard parts.count == 2, let resume = UInt64(parts[0]), let size = UInt64(parts[1]) else { return nil }
        return (resume, size)
    }

    private static func readChunk(from url: URL, startingAt offset: UInt64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            if offset > 0 { try handle.seek(toOffset: offset) }
            return try handle.readToEnd() ?? Data()
        } catch {
            return nil
        }
    }

    package static func parseTranscript(
        _ content: String, conversationID: String, recordedProject: String? = nil, since: Double
    ) -> (evidence: [Evidence], project: String?) {
        let parsed = parseTranscriptData(
            Data(content.utf8),
            baseOffset: 0,
            conversationID: conversationID,
            recordedProject: recordedProject,
            since: since
        )
        return (parsed.evidence, parsed.project)
    }

    private static func parseTranscriptData(
        _ data: Data,
        baseOffset: UInt64,
        conversationID: String,
        recordedProject: String? = nil,
        since: Double
    ) -> (evidence: [Evidence], project: String?, nextResumeOffset: UInt64) {
        var steps: [(offset: UInt64, object: [String: Any])] = []
        var consumedOffset = baseOffset
        var lineStart = data.startIndex
        while lineStart < data.endIndex {
            let newlineIndex = data[lineStart...].firstIndex(of: 10)
            let lineEnd = newlineIndex ?? data.endIndex
            let slice = data[lineStart..<lineEnd]
            let absoluteLineStart = baseOffset + UInt64(lineStart - data.startIndex)
            let absoluteLineEnd = baseOffset + UInt64((newlineIndex.map { $0 + 1 } ?? data.endIndex) - data.startIndex)

            if slice.isEmpty {
                consumedOffset = absoluteLineEnd
            } else if let object = try? JSONSerialization.jsonObject(with: slice) as? [String: Any] {
                steps.append((absoluteLineStart, object))
                consumedOffset = absoluteLineEnd
            } else if newlineIndex != nil {
                // Malformed complete line; skip past it.
                consumedOffset = absoluteLineEnd
            } else {
                // Potentially truncated trailing line without newline; stop before it so next scan retries.
                break
            }

            if let newlineIndex {
                lineStart = newlineIndex + 1
            } else {
                break
            }
        }

        let project = recordedProject.flatMap { $0.hasPrefix("/") ? ProjectIdentity.resolve($0) : nil }
            ?? inferProject(from: steps.map(\.object))
        guard let project, !project.isEmpty else {
            return ([], nil, baseOffset)
        }

        struct Turn {
            let startOffset: UInt64
            let stepIndex: Int
            let user: String
            var finalAnswer: String = ""
            var completedAt: Double?
            var isDream: Bool = false
        }

        var turns: [Turn] = []
        var current: Turn?

        for entry in steps {
            let step = entry.object
            let type = step["type"] as? String ?? ""
            let status = step["status"] as? String ?? ""
            if type == "USER_INPUT" {
                if let existing = current { turns.append(existing) }
                let rawContent = step["content"] as? String ?? ""
                let userText = extractUserRequest(from: rawContent)
                let idx = step["step_index"] as? Int ?? turns.count
                current = Turn(startOffset: entry.offset, stepIndex: idx, user: userText)
            } else if type == "PLANNER_RESPONSE", var active = current {
                if let toolCalls = step["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
                    if toolCalls.contains(where: isDreamToolCall) {
                        active.isDream = true
                    }
                } else if status == "DONE" {
                    let text = (step["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        active.finalAnswer = text
                        active.completedAt = parseISO8601(step["created_at"] as? String)
                    }
                }
                current = active
            }
        }
        if let existing = current { turns.append(existing) }

        var out: [Evidence] = []
        for turn in turns {
            guard !turn.isDream,
                  let completedAt = turn.completedAt,
                  completedAt >= since else { continue }
            let user = turn.user
            let final = turn.finalAnswer
            guard !user.isEmpty, !SecretFilter.contains(user), !SecretFilter.contains(final) else { continue }
            if shouldSkip(user: user, final: final) { continue }
            let excerpt = "用户\n" + String(user.prefix(1400)) + (final.isEmpty ? "" : "\n\nAntigravity\n" + String(final.prefix(900)))
            out.append(Evidence(
                id: "antigravity:\(conversationID):\(turn.stepIndex)",
                threadID: conversationID,
                turnID: String(turn.stepIndex),
                project: project,
                timestamp: completedAt,
                excerpt: excerpt
            ))
        }

        let nextResumeOffset: UInt64
        if let lastTurn = turns.last, lastTurn.completedAt == nil {
            nextResumeOffset = lastTurn.startOffset
        } else {
            nextResumeOffset = consumedOffset
        }
        return (out, project, nextResumeOffset)
    }

    private static func extractUserRequest(from raw: String) -> String {
        if let start = raw.range(of: "<USER_REQUEST>"),
           let end = raw.range(of: "</USER_REQUEST>", range: start.upperBound..<raw.endIndex) {
            return String(raw[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isDreamToolCall(_ call: [String: Any]) -> Bool {
        let dreamTools = MCPTools.dreamToolNames
        if let name = call["name"] as? String, dreamTools.contains(where: { name.contains($0) }) {
            return true
        }
        if let args = call["args"] as? [String: Any] {
            for key in ["ToolName", "tool_name", "name"] {
                if let value = args[key] as? String, dreamTools.contains(where: { value.contains($0) }) {
                    return true
                }
            }
        }
        return false
    }

    private static func shouldSkip(user: String, final: String) -> Bool {
        if user.hasPrefix(batchDreamPrefix) ||
            user.hasPrefix(CodexSetup.setupPromptTitle) ||
            user.hasPrefix(AntigravitySetup.setupPromptTitle) ||
            user == CodexSetup.testPrompt ||
            user == AntigravitySetup.testPrompt ||
            user == AntigravitySetup.verifyPrompt ||
            user.contains(AntigravitySetup.verifyQuery) {
            return true
        }
        if user.range(of: #"(?i)\bdream-[0-9a-f]{8}-[0-9a-f-]{27}\b"#, options: .regularExpression) != nil ||
            final.range(of: #"(?i)\bdream-[0-9a-f]{8}-[0-9a-f-]{27}\b"#, options: .regularExpression) != nil {
            return true
        }
        let cleaned = user.trimmingCharacters(in: .punctuationCharacters)
        if ["帮我做梦", "做梦", "帮我把这批记忆做梦并写回", "使用 agent-memory MCP 工具帮我做梦，并写回这一批结果"]
            .contains(cleaned) {
            return true
        }
        return false
    }

    private static func inferProject(from steps: [[String: Any]]) -> String? {
        var counts: [String: Int] = [:]
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let ignoredPrefixes = [
            home + "/.gemini/",
            "/tmp/",
            "/private/tmp/",
            "/var/",
            "/private/var/",
            "/Library/",
            "/System/",
            "/Applications/"
        ]

        func consider(_ rawPath: String) {
            var path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if path.hasPrefix("\"") && path.hasSuffix("\"") && path.count >= 2 {
                path = String(path.dropFirst().dropLast())
            }
            path = path.replacingOccurrences(of: "\\\"", with: "\"")
            guard path.hasPrefix("/") else { return }
            guard !ignoredPrefixes.contains(where: { path.hasPrefix($0) }) else { return }
            var isDir: ObjCBool = false
            let candidateDir: String
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
                candidateDir = isDir.boolValue ? path : URL(fileURLWithPath: path).deletingLastPathComponent().path
            } else {
                // Path may have been moved/deleted; strip last component if it looks like a file.
                let url = URL(fileURLWithPath: path)
                candidateDir = url.pathExtension.isEmpty ? path : url.deletingLastPathComponent().path
            }
            let resolved = ProjectIdentity.resolve(candidateDir)
            guard !resolved.isEmpty, resolved != "/", resolved != home else { return }
            counts[resolved, default: 0] += 1
        }

        let mentionRegex = try? NSRegularExpression(pattern: #"@\[(/[^\]\n]+)\]"#)

        for step in steps {
            if let type = step["type"] as? String, type == "USER_INPUT", let content = step["content"] as? String,
               let regex = mentionRegex {
                let ns = content as NSString
                for match in regex.matches(in: content, range: NSRange(location: 0, length: ns.length)) {
                    if match.numberOfRanges > 1 {
                        consider(ns.substring(with: match.range(at: 1)))
                    }
                }
            }
            if let toolCalls = step["tool_calls"] as? [[String: Any]] {
                for call in toolCalls {
                    guard let args = call["args"] as? [String: Any] else { continue }
                    for key in ["Path", "Cwd", "Directory", "TargetFile", "AbsolutePath"] {
                        if let value = args[key] as? String { consider(value) }
                    }
                }
            }
        }

        return counts.max(by: { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lhs.key.count > rhs.key.count
        })?.key
    }

    private static func parseISO8601(_ value: String?) -> Double? {
        guard let value else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: value) { return date.timeIntervalSince1970 }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)?.timeIntervalSince1970
    }
}
