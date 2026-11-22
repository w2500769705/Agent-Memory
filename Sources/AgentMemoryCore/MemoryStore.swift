import Foundation
import GRDB

public final class MemoryStore: @unchecked Sendable {
    private let database: DatabaseQueue
    // Accessed only on the DatabaseQueue. The revision is committed with changes to active vectors.
    private var vectorCache: (revision: Int64, vectors: [String: [Float]])?
    private let duplicatePairsLock = NSLock()
    private var duplicatePairsCache: (revision: Int64, pairs: [MemoryHealthSummary.DuplicatePair])?
    private let recallLock = NSLock()
    private struct RecallSessionKey: Hashable {
        let agent: ActivityEvent.Agent
        let threadID: String
    }

    private struct RecallSession {
        var lastQuery: String?
        var turn = 0
        var lastSeen: Date
        var injected: [String: (version: Int, turn: Int, timestamp: Date)] = [:]
    }

    private var recallSessions: [RecallSessionKey: RecallSession] = [:]
    private static let recallTurnWindow = 12
    private static let recallTimeWindow: TimeInterval = 45 * 60
    private static let maxRecallSessions = 512

    private let recallDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    public init(path: String) throws {
        database = try DatabaseQueue(path: path)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("initial") { db in
            try db.execute(sql: """
                CREATE TABLE setting (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE evidence (
                    id TEXT PRIMARY KEY, thread TEXT NOT NULL, project TEXT NOT NULL,
                    time REAL NOT NULL, state TEXT NOT NULL DEFAULT 'queued', payload BLOB NOT NULL
                );
                CREATE INDEX evidence_queue ON evidence(state, time);
                CREATE TABLE batch (
                    id TEXT PRIMARY KEY, expires REAL NOT NULL, payload BLOB NOT NULL,
                    submission BLOB, response BLOB, reversed INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE batch_evidence (
                    batch_id TEXT NOT NULL REFERENCES batch(id), evidence_id TEXT NOT NULL REFERENCES evidence(id),
                    PRIMARY KEY(batch_id, evidence_id)
                );
                CREATE TABLE decision (
                    id TEXT PRIMARY KEY, batch_id TEXT NOT NULL REFERENCES batch(id), status TEXT NOT NULL,
                    payload BLOB NOT NULL
                );
                CREATE TABLE memory (
                    id TEXT PRIMARY KEY, project TEXT, archived INTEGER NOT NULL,
                    updated REAL NOT NULL, payload BLOB NOT NULL, vectors BLOB
                );
                CREATE VIRTUAL TABLE memory_fts USING fts5(id UNINDEXED, title, body);
                CREATE TABLE history (
                    id INTEGER PRIMARY KEY, memory_id TEXT NOT NULL, batch_id TEXT NOT NULL,
                    previous BLOB, current BLOB NOT NULL
                );
                CREATE INDEX history_memory ON history(memory_id, id);
                """)
        }
        migrator.registerMigration("activity_log") { db in
            try db.execute(sql: """
                CREATE TABLE activity_log (
                    id INTEGER PRIMARY KEY, kind TEXT NOT NULL, time REAL NOT NULL,
                    agent TEXT, project TEXT, memory_ids BLOB, count INTEGER,
                    estimated_tokens INTEGER, batch_id TEXT, message TEXT
                );
                CREATE INDEX activity_recent ON activity_log(time, id);
                CREATE INDEX activity_kind_time ON activity_log(kind, time);
                """)
        }
        migrator.registerMigration("memory_health_and_inspection") { db in
            try db.execute(sql: """
                ALTER TABLE memory ADD COLUMN hit_count INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE memory ADD COLUMN last_hit_at REAL;
                ALTER TABLE memory ADD COLUMN content_version INTEGER NOT NULL DEFAULT 1;
                UPDATE memory SET content_version = json_extract(CAST(payload AS TEXT), '$.version');
                CREATE INDEX memory_health_age ON memory(archived, hit_count, updated);
                CREATE TABLE vector_revision (revision INTEGER NOT NULL);
                INSERT INTO vector_revision VALUES (0);
                CREATE TRIGGER vector_revision_insert AFTER INSERT ON memory WHEN NEW.archived = 0 BEGIN
                    UPDATE vector_revision SET revision = revision + 1;
                END;
                CREATE TRIGGER vector_revision_update AFTER UPDATE OF vectors, archived, content_version ON memory
                WHEN (OLD.archived <> NEW.archived OR (NEW.archived = 0 AND
                      (OLD.vectors IS NOT NEW.vectors OR OLD.content_version <> NEW.content_version))) BEGIN
                    UPDATE vector_revision SET revision = revision + 1;
                END;
                CREATE TRIGGER vector_revision_delete AFTER DELETE ON memory WHEN OLD.archived = 0 BEGIN
                    UPDATE vector_revision SET revision = revision + 1;
                END;
                ALTER TABLE batch ADD COLUMN created_at REAL NOT NULL DEFAULT 0;
                UPDATE batch SET created_at = expires - 1800 WHERE expires >= 1800;
                CREATE INDEX decision_batch_status ON decision(batch_id, status);
                CREATE INDEX history_batch ON history(batch_id);
                """)
        }
        try migrator.migrate(database)
    }

    public static let recallCrossProjectKey = "recallCrossProject"
    public static let smartCaptureKey = "smartCapture"

    public func setting(_ key: String) throws -> String? {
        try database.read { try String.fetchOne($0, sql: "SELECT value FROM setting WHERE key = ?", arguments: [key]) }
    }

    public func isSmartCaptureEnabled() throws -> Bool {
        try setting(Self.smartCaptureKey) != "0"
    }

    public func configureSmartCapture(_ enabled: Bool) throws {
        try setSetting(Self.smartCaptureKey, enabled ? "1" : "0")
    }

    public func configureRecallCrossProject(_ enabled: Bool) throws {
        recallLock.lock()
        defer { recallLock.unlock() }
        try setSetting(Self.recallCrossProjectKey, enabled ? "1" : "0")
        // A scope change should make newly eligible results available immediately.
        recallSessions.removeAll()
    }

    func configureRecall(_ enabled: Bool, agent: String = "codex") throws {
        let source = ActivityEvent.Agent(rawValue: agent) ?? .codex
        let enabledKey = source == .antigravity ? "antigravityRecallEnabled" : "recallEnabled"
        let verifiedKey = source == .antigravity ? "antigravityRecallVerifiedAt" : "recallVerifiedAt"
        recallLock.lock()
        defer { recallLock.unlock() }
        let changed = try database.write { db in
            let current = try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ?", arguments: [enabledKey])
            try Self.setSetting(db, enabledKey, enabled ? "1" : "0")
            if !enabled || current != "1" {
                try db.execute(sql: "DELETE FROM setting WHERE key = ?", arguments: [verifiedKey])
            }
            return (current == "1") != enabled
        }
        if changed {
            recallSessions = recallSessions.filter { $0.key.agent != source }
        }
    }

    func recallContext(query: String, project: String, threadID: String, agent: String = "codex",
                       deliver: (String) throws -> Void) throws {
        let deadline = DispatchTime.now() + .milliseconds(1_900)
        let project = ProjectIdentity.resolve(project)
        let agent = ActivityEvent.Agent(rawValue: agent) ?? .codex
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !project.isEmpty, !query.isEmpty, query.count <= 1_000, !SecretFilter.contains(query) else { return try deliver("") }
        if agent == .antigravity, !threadID.isEmpty {
            let key = "antigravityProject:\(threadID)"
            if (try? setting(key)) != project { try? setSetting(key, project) }
        }
        guard !RecallHook.isLowInformation(query) else { return try deliver("") }
        recallLock.lock()
        defer { recallLock.unlock() }
        guard DispatchTime.now() < deadline else { return try deliver("") }
        let enabledKey = agent == .antigravity ? "antigravityRecallEnabled" : "recallEnabled"
        let verifiedKey = agent == .antigravity ? "antigravityRecallVerifiedAt" : "recallVerifiedAt"
        guard try setting(enabledKey) == "1" else { return try deliver("") }
        if query == CodexSetup.testPrompt || query == AntigravitySetup.testPrompt {
            try setSetting(verifiedKey, String(Date().timeIntervalSince1970))
            return try deliver("Agent Memory 的验证请求已收到。本次为连接测试，未检索个人记忆。请用户到 Agent Memory 概览查看确认状态。")
        }

        let now = Date()
        let sessionKey = RecallSessionKey(agent: agent, threadID: threadID)
        var session = recallSessions[sessionKey] ?? RecallSession(lastSeen: now)
        if now.timeIntervalSince(session.lastSeen) >= Self.recallTimeWindow {
            session = RecallSession(lastSeen: now)
        }
        if session.lastQuery != query {
            session.turn += 1
            session.lastQuery = query
        }
        session.lastSeen = now
        session.injected = session.injected.filter {
            session.turn - $0.value.turn <= Self.recallTurnWindow &&
                now.timeIntervalSince($0.value.timestamp) < Self.recallTimeWindow
        }

        let crossProject = try setting(Self.recallCrossProjectKey) == "1"
        let relevant = try database.read { db in
            let excluded = try Self.exclusions(db)
            guard !excluded.projects.contains(project), !excluded.threads.contains(threadID) else { return [SearchHit]() }
            return try search(db, query, scope: crossProject ? .all : .projectAndGlobal(project), limit: 3,
                              requireRecallRelevance: true).hits
        }
        guard DispatchTime.now() < deadline else { return try deliver("") }
        let selected = relevant.prefix(3).filter { session.injected[$0.id]?.version != $0.memory.version }.map(\.memory)

        if selected.isEmpty {
            try deliver("")
        } else {
            let notes = selected.map { memory -> String in
                let date = recallDateFormatter.string(from: Date(timeIntervalSince1970: memory.updated))
                return "- [\(date)] \(memory.title)：\(memory.body.prefix(360))"
            }.joined(separator: "\n")
            let context: String = "Agent Memory 检索到的历史参考。用户本轮要求优先。历史记忆若有冲突，以较新日期为准，并与实际情况核对。\n" + notes
            let ascii = context.unicodeScalars.filter(\.isASCII).count
            let tokens = (ascii + 3) / 4 + context.unicodeScalars.count - ascii
            let delivered = try database.write { db in
                guard DispatchTime.now() < deadline else {
                    try deliver("")
                    return false
                }
                let ids = selected.map(\.id)
                try Self.recordHits(db, ids: ids)
                try Self.insertActivity(db, .recall, agent: agent, project: project,
                                        memoryIDs: ids, count: ids.count, estimatedTokens: tokens)
                // A failed socket write rolls back both the hit counters and the activity.
                try deliver(context)
                return true
            }
            guard delivered else { return }
        }

        if !threadID.isEmpty {
            for memory in selected { session.injected[memory.id] = (memory.version, session.turn, now) }
            if recallSessions.count >= Self.maxRecallSessions, recallSessions[sessionKey] == nil,
               let oldest = recallSessions.min(by: { $0.value.lastSeen < $1.value.lastSeen }) {
                recallSessions.removeValue(forKey: oldest.key)
            }
            recallSessions[sessionKey] = session
        }
    }

    public func recentActivities(limit: Int = 50) throws -> [ActivityEvent] {
        try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM activity_log ORDER BY time DESC, id DESC LIMIT ?
                """, arguments: [min(max(0, limit), 500)]).map { row in
                let kind: String = row["kind"]
                let timestamp: Double = row["time"]
                let agent: String? = row["agent"]
                let memoryIDs: Data? = row["memory_ids"]
                guard let activityKind = ActivityEvent.Kind(rawValue: kind) else {
                    throw MemoryError.invalid("无法读取活动类型。")
                }
                return ActivityEvent(id: row["id"], kind: activityKind, timestamp: Date(timeIntervalSince1970: timestamp),
                                     agent: agent.flatMap(ActivityEvent.Agent.init(rawValue:)), project: row["project"],
                                     memoryIDs: try memoryIDs.map { try Wire.decode([String].self, $0) } ?? [],
                                     count: row["count"], estimatedTokens: row["estimated_tokens"],
                                     batchID: row["batch_id"], message: row["message"])
            }
        }
    }

    public func todayRecallTotals() throws -> (count: Int, estimatedTokens: Int) {
        let now = Date()
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? now
        return try database.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT count(*) AS recalls, coalesce(sum(estimated_tokens), 0) AS tokens
                FROM activity_log WHERE kind = 'recall' AND time >= ? AND time < ?
                """, arguments: [start.timeIntervalSince1970, end.timeIntervalSince1970])
            guard let row else { return (0, 0) }
            return (row["recalls"], row["tokens"])
        }
    }

    public func recordError(_ error: Error, operation: String, agent: ActivityEvent.Agent? = nil) {
        let nsError = error as NSError
        let detail = (error as? MemoryError)?.localizedDescription ?? "\(nsError.domain) (\(nsError.code))"
        let message = SecretFilter.contains(detail) ? operation : "\(operation)：\(detail)"
        try? database.write { try Self.insertActivity($0, .error, agent: agent, message: String(message.prefix(240))) }
    }

    private static func insertActivity(_ db: Database, _ kind: ActivityEvent.Kind, agent: ActivityEvent.Agent? = nil,
                                       project: String? = nil, memoryIDs: [String] = [], count: Int? = nil,
                                       estimatedTokens: Int? = nil, batchID: String? = nil, message: String? = nil) throws {
        let ids = memoryIDs.isEmpty ? nil : try Wire.data(memoryIDs)
        let safeProject = project.flatMap { SecretFilter.contains($0) ? nil : $0 }
        try db.execute(sql: """
            INSERT INTO activity_log (kind,time,agent,project,memory_ids,count,estimated_tokens,batch_id,message)
            VALUES (?,?,?,?,?,?,?,?,?)
            """, arguments: [kind.rawValue, Date().timeIntervalSince1970, agent?.rawValue, safeProject, ids,
                             count, estimatedTokens, batchID, message])
    }

    public func setSetting(_ key: String, _ value: String) throws {
        try database.write { try Self.setSetting($0, key, value) }
    }

    private static func setSetting(_ db: Database, _ key: String, _ value: String) throws {
        try db.execute(sql: "INSERT INTO setting VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                       arguments: [key, value])
    }

    @discardableResult
    public func ingest(_ rows: [Evidence], scannedFrom: Double? = nil, checkpoint: Double? = nil,
                       enabledKey: String = "enabled", cursorKey: String = "scanSince") throws -> Int {
        try ingest(rows, scannedFrom: scannedFrom, checkpoint: checkpoint, enabledKey: enabledKey, cursorKey: cursorKey, scanAgent: nil)
    }

    func ingest(_ rows: [Evidence], scannedFrom: Double?, checkpoint: Double?,
                enabledKey: String, cursorKey: String, scanAgent: ActivityEvent.Agent?) throws -> Int {
        try database.write { db in
            if let scannedFrom {
                let active = try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ?", arguments: [enabledKey])
                let current = try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ?", arguments: [cursorKey])
                guard active == "1", current.flatMap(Double.init) == scannedFrom else { return 0 }
            }
            let exclusions = try Self.exclusions(db)
            var inserted = 0
            for row in rows where !row.project.isEmpty && !SecretFilter.contains(row.excerpt) {
                guard !exclusions.projects.contains(row.project), !exclusions.threads.contains(row.threadID) else { continue }
                try db.execute(sql: "INSERT OR IGNORE INTO evidence (id,thread,project,time,payload) VALUES (?,?,?,?,?)",
                               arguments: [row.id, row.threadID, row.project, row.timestamp, try Wire.data(row)])
                inserted += db.changesCount
            }
            if let checkpoint { try Self.setSetting(db, cursorKey, String(checkpoint)) }
            if let scanAgent {
                try Self.insertActivity(db, .scan, agent: scanAgent, count: inserted)
            }
            return inserted
        }
    }

    public func configureCapture(enabled: Bool, resetTo: Double? = nil,
                                 enabledKey: String = "enabled", cursorKey: String = "scanSince") throws {
        try database.write { db in
            let prior = try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ?", arguments: [cursorKey])
            if let start = resetTo ?? (enabled && prior == nil ? floor(Date().timeIntervalSince1970) : nil) {
                try Self.setSetting(db, cursorKey, String(start))
                if resetTo != nil && cursorKey == AntigravitySource.cursorKey {
                    try db.execute(sql: "DELETE FROM setting WHERE key LIKE 'antigravityOffset:%'")
                }
            }
            try Self.setSetting(db, enabledKey, enabled ? "1" : "0")
        }
    }

    public func exclude(_ evidence: Evidence, project: Bool) throws {
        try database.write { db in
            let key = project ? "excludedProjects" : "excludedThreads"
            let value = project ? evidence.project : evidence.threadID
            let current = try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ?", arguments: [key]) ?? ""
            let excluded = Set(current.split(separator: "\n").map(String.init)).union([value])
            try Self.setSetting(db, key, excluded.sorted().joined(separator: "\n"))
            let column = project ? "project" : "thread"
            try db.execute(sql: "UPDATE evidence SET state = 'excluded' WHERE \(column) = ? AND state IN ('queued', 'claimed')",
                           arguments: [value])
            try db.execute(sql: """
                UPDATE batch SET expires = 0 WHERE response IS NULL AND id IN (
                    SELECT be.batch_id FROM batch_evidence be JOIN evidence e ON e.id = be.evidence_id
                    WHERE e.state = 'excluded'
                )
                """)
            try Self.releaseExpired(db)
        }
    }

    private static func exclusions(_ db: Database) throws -> (projects: Set<String>, threads: Set<String>) {
        func list(_ key: String) throws -> Set<String> {
            let value = try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ?", arguments: [key]) ?? ""
            return Set(value.split(separator: "\n").map(String.init))
        }
        return (try list("excludedProjects"), try list("excludedThreads"))
    }

    public func dashboard() throws -> Dashboard {
        try database.write { db in
            try Self.releaseExpired(db)
            func count(_ table: String, _ predicate: String) throws -> Int {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE \(predicate)") ?? 0
            }
            return try Dashboard(
                memories: count("memory", "archived = 0"),
                pending: count("evidence", "state IN ('queued', 'claimed')"),
                queuedThrough: Int64.fetchOne(db, sql: "SELECT MAX(rowid) FROM evidence WHERE state = 'queued'"),
                review: count("decision", "status = 'review'"),
                evidence: Data.fetchAll(db, sql: "SELECT payload FROM evidence WHERE state IN ('queued','claimed') ORDER BY time DESC LIMIT 200")
                    .map { try Wire.decode(Evidence.self, $0) },
                decisions: Data.fetchAll(db, sql: "SELECT payload FROM decision WHERE status IN ('review','conflict') ORDER BY rowid DESC LIMIT 100")
                    .map { try Wire.decode(Decision.self, $0) },
                batches: String.fetchAll(db, sql: "SELECT id FROM batch WHERE response IS NOT NULL AND reversed = 0 ORDER BY rowid DESC LIMIT 30"),
                batchSummaries: Self.dreamBatchSummaries(db)
            )
        }
    }

    /// Recent submitted batches, including those that were rolled back.
    public func dreamBatchSummaries() throws -> [DreamBatchSummary] {
        try database.read { try Self.dreamBatchSummaries($0) }
    }

    private static func dreamBatchSummaries(_ db: Database) throws -> [DreamBatchSummary] {
        try Row.fetchAll(db, sql: """
            SELECT b.id, b.created_at,
                   (SELECT COUNT(*) FROM decision WHERE batch_id = b.id AND status = 'applied') AS applied,
                   (SELECT COUNT(*) FROM decision WHERE batch_id = b.id AND status = 'review') AS pending,
                   (SELECT COUNT(*) FROM decision WHERE batch_id = b.id AND status = 'conflict') AS conflicts,
                   b.reversed = 0 AND NOT EXISTS (
                       SELECT 1 FROM history h LEFT JOIN memory m ON m.id = h.memory_id
                       WHERE h.batch_id = b.id AND (
                           m.id IS NULL OR m.content_version <> json_extract(CAST(h.current AS TEXT), '$.version')
                       )
                   ) AS can_rollback
            FROM batch b WHERE b.response IS NOT NULL ORDER BY b.rowid DESC LIMIT 30
            """).map { row in
                DreamBatchSummary(batchID: row["id"], createdAt: row["created_at"], appliedCount: row["applied"],
                                  pendingCount: row["pending"], conflictCount: row["conflicts"],
                                  canRollback: row["can_rollback"])
            }
    }

    public func evidence(_ ids: [String]) throws -> [Evidence] {
        guard !ids.isEmpty else { return [] }
        return try database.read { db in
            var byID: [String: Evidence] = [:]
            let uniqueIDs = Array(Set(ids))
            for start in stride(from: 0, to: uniqueIDs.count, by: 500) {
                let chunk = uniqueIDs[start..<min(start + 500, uniqueIDs.count)]
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
                let payloads = try Data.fetchAll(db, sql: "SELECT payload FROM evidence WHERE id IN (\(placeholders))",
                                                 arguments: StatementArguments(chunk))
                for data in payloads {
                    let item = try Wire.decode(Evidence.self, data)
                    byID[item.id] = item
                }
            }
            return ids.compactMap { byID[$0] }
        }
    }

    public func history(_ memoryID: String) throws -> [HistoryItem] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM history WHERE memory_id = ? ORDER BY id DESC",
                             arguments: [memoryID]).map(Self.historyItem)
        }
    }

    private static func historyItem(_ row: Row) throws -> HistoryItem {
        let previous: Data? = row["previous"]
        return try HistoryItem(id: row["id"], batchID: row["batch_id"],
                               previous: previous.map { try Wire.decode(Memory.self, $0) },
                               current: Wire.decode(Memory.self, row["current"]))
    }

    public func search(_ query: String, project: String? = nil, limit: Int = 20,
                       recordActivity: Bool = true) throws -> [SearchHit] {
        let scope = project.map(SearchScope.projectAndGlobal) ?? .all
        let hits = try database.read { try search($0, query, scope: scope, limit: min(max(limit, 1), 50)).hits }
        if recordActivity, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            recordSearch(count: hits.count, project: project)
        }
        return hits
    }

    /// Read-only inspection of automatic recall, without session deduplication.
    public func inspectSearch(_ query: String, scope: SearchScope = .all, limit: Int = 20,
                              includeFilteredCandidates: Bool = false) throws -> SearchInspection {
        let start = DispatchTime.now().uptimeNanoseconds
        let results = try database.read { db in
            try search(db, query, scope: scope, limit: min(max(limit, 1), 50),
                       requireRecallRelevance: true,
                       includeFilteredCandidates: includeFilteredCandidates)
        }
        let elapsedMs = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        return SearchInspection(hits: results.hits, filteredCandidates: results.filtered, elapsedMs: elapsedMs)
    }

    private func recordSearch(count: Int, project: String?) {
        try? database.write { db in
            try Self.insertActivity(db, .search, project: project.map(ProjectIdentity.resolve), count: count)
        }
    }

    func deliverSearch(_ hits: [SearchHit], project: String?, deliver: () throws -> Void) throws {
        // An MCP page can be large. Let the peer drain the response without holding the database.
        try deliver()
        let scope = project.map(ProjectIdentity.resolve)
        try database.write { db in
            try Self.recordHits(db, ids: hits.map(\.id))
            try Self.insertActivity(db, .search, project: scope, count: hits.count)
        }
    }

    private static func recordHits(_ db: Database, ids: [String]) throws {
        guard !ids.isEmpty else { return }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        try db.execute(sql: """
            UPDATE memory SET hit_count = hit_count + 1, last_hit_at = ?
            WHERE id IN (\(placeholders))
            """, arguments: [Date().timeIntervalSince1970] + StatementArguments(ids))
    }

    private static func vectorRevision(_ db: Database) throws -> Int64 {
        try Int64.fetchOne(db, sql: "SELECT revision FROM vector_revision") ?? 0
    }

    private func activeVectors(_ db: Database, cacheResult: Bool = true) throws -> [String: [Float]] {
        let revision = try Self.vectorRevision(db)
        if let vectorCache, vectorCache.revision == revision { return vectorCache.vectors }
        var vectors: [String: [Float]] = [:]
        let rows = try Row.fetchCursor(db, sql: "SELECT id, vectors FROM memory WHERE archived = 0 AND vectors IS NOT NULL")
        while let row = try rows.next() {
            let data: Data = row["vectors"]
            guard let stored = try? Wire.decode([Retrieval.Vector].self, data),
                  let vector = Retrieval.currentVector(from: stored) else { continue }
            vectors[row["id"] as String] = vector
        }
        if cacheResult { vectorCache = (revision, vectors) }
        return vectors
    }

    private func search(_ db: Database, _ query: String, scope: SearchScope = .all, limit: Int,
                        requireRecallRelevance: Bool = false,
                        includeFilteredCandidates: Bool = false,
                        cacheVectors: Bool = true) throws -> (hits: [SearchHit], filtered: [SearchHit]) {
        let scopePredicate: String
        let scopeArgs: StatementArguments
        switch scope {
        case .all:
            scopePredicate = ""
            scopeArgs = []
        case .global:
            scopePredicate = " AND m.project IS NULL"
            scopeArgs = []
        case .project(let path):
            scopePredicate = " AND m.project = ?"
            scopeArgs = [ProjectIdentity.resolve(path)]
        case .projectAndGlobal(let path):
            scopePredicate = " AND (m.project = ? OR m.project IS NULL)"
            scopeArgs = [ProjectIdentity.resolve(path)]
        }
        let predicate = "m.archived = 0" + scopePredicate
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let rows = try Row.fetchAll(db, sql: """
                SELECT m.payload, m.hit_count, m.last_hit_at FROM memory m WHERE \(predicate)
                ORDER BY m.updated DESC, m.id LIMIT ?
                """, arguments: scopeArgs + [limit])
            let hits = try rows.map {
                SearchHit(memory: try Self.memory($0), vector: nil, keywordRank: nil, score: 0)
            }
            return (hits, [])
        }

        let recallTerms = requireRecallRelevance ? Retrieval.recallTerms(query) : []
        let phrase = requireRecallRelevance ? Retrieval.recallPhrase(recallTerms) : Retrieval.phrase(query)
        let keywords = phrase.isEmpty ? [] : try String.fetchAll(db, sql: """
            SELECT m.id FROM memory_fts JOIN memory m ON m.id = memory_fts.id
            WHERE memory_fts MATCH ? AND \(predicate) ORDER BY bm25(memory_fts, 0, 3, 1), m.id LIMIT 100
            """, arguments: [phrase] + scopeArgs)
        let byKeyword = Dictionary(uniqueKeysWithValues: keywords.enumerated().map { ($0.element, $0.offset + 1) })
        let queryVector = Retrieval.currentVector(from: Retrieval.vectors(query))
        let rows = try Row.fetchAll(db, sql: "SELECT m.id, m.updated FROM memory m WHERE \(predicate)", arguments: scopeArgs)
        let updatedByID = Dictionary(uniqueKeysWithValues: rows.map { ($0["id"] as String, $0["updated"] as Double) })
        var vectorMatches: [(id: String, similarity: Double)] = []
        var edgeMatches: [(id: String, similarity: Double)] = []
        var keywordSimilarities: [String: Double] = [:]
        if let queryVector {
            let indexed = try activeVectors(db, cacheResult: cacheVectors)
            for id in updatedByID.keys {
                guard let candidate = indexed[id] else { continue }
                let value = Retrieval.similarity(queryVector, candidate)
                // Even a similarity below the vector shortlist cutoff must veto keyword fallback.
                if requireRecallRelevance, byKeyword[id] != nil { keywordSimilarities[id] = value }
                if value >= Retrieval.vectorThreshold {
                    vectorMatches.append((id, value))
                } else if includeFilteredCandidates, value >= Retrieval.inspectionThreshold, byKeyword[id] == nil {
                    edgeMatches.append((id, value))
                }
            }
        }
        vectorMatches.sort { $0.similarity == $1.similarity ? $0.id < $1.id : $0.similarity > $1.similarity }
        edgeMatches.sort { $0.similarity == $1.similarity ? $0.id < $1.id : $0.similarity > $1.similarity }
        let byVector = Dictionary(uniqueKeysWithValues: vectorMatches.prefix(100).enumerated().map {
            ($0.element.id, (rank: $0.offset + 1, similarity: $0.element.similarity))
        })
        let ranked = Set(byKeyword.keys).union(byVector.keys).map { id in
            let keywordScore = byKeyword[id].map { 0.45 / (60 + Double($0)) } ?? 0
            let vectorScore = byVector[id].map { 0.55 / (60 + Double($0.rank)) } ?? 0
            return (id: id, score: keywordScore + vectorScore)
        }.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            let lhs = updatedByID[$0.id] ?? 0
            let rhs = updatedByID[$1.id] ?? 0
            return lhs == rhs ? $0.id < $1.id : lhs > rhs
        }

        let candidates = requireRecallRelevance ? ranked[...] : ranked.prefix(limit)
        let edges = edgeMatches.prefix(10)
        let ids = candidates.map(\.id) + edges.map(\.id)
        guard !ids.isEmpty else { return ([], []) }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        let memories = try Row.fetchAll(db, sql: """
            SELECT payload, hit_count, last_hit_at FROM memory WHERE id IN (\(placeholders))
            """, arguments: StatementArguments(ids)).map(Self.memory)
        let byID = Dictionary(uniqueKeysWithValues: memories.map { ($0.id, $0) })
        var hits: [SearchHit] = []
        var filtered: [SearchHit] = []
        for item in candidates {
            guard let memory = byID[item.id] else { continue }
            let hit = SearchHit(memory: memory, vector: byVector[item.id]?.similarity ?? keywordSimilarities[item.id],
                                keywordRank: byKeyword[item.id], score: item.score)
            if !requireRecallRelevance || Self.isRelevantForRecall(hit, queryTerms: recallTerms) {
                if hits.count < limit { hits.append(hit) }
            } else if includeFilteredCandidates, filtered.count < 10 {
                filtered.append(hit)
            }
            if hits.count == limit, !includeFilteredCandidates || filtered.count == 10 { break }
        }
        filtered += edges.prefix(10 - filtered.count).compactMap { item in
            byID[item.id].map { SearchHit(memory: $0, vector: item.similarity, keywordRank: nil, score: 0) }
        }
        return (hits, filtered)
    }

    private static func isRelevantForRecall(_ hit: SearchHit, queryTerms: Set<String>) -> Bool {
        if let vector = hit.vector {
            guard vector >= 0.42 else { return false }
            if vector >= 0.62 { return true }
            guard vector >= 0.50 else { return false }
        } else if hit.keywordRank == nil {
            return false
        }
        guard !queryTerms.isEmpty else { return false }
        let matches = queryTerms.intersection(Retrieval.recallTerms(hit.memory.title + " " + hit.memory.body))
        if hit.vector != nil {
            return matches.count >= 2 || matches.contains(where: Retrieval.isTechnicalTerm)
        }
        return matches.count >= 3 || Double(matches.count) / Double(queryTerms.count) >= 0.35
    }

    public func memoryHealthSummary() throws -> MemoryHealthSummary {
        let cutoff = Date().timeIntervalSince1970 - 30 * 86_400
        let (activeCount, archivedCount, dormantIDs, cachedPairs, candidates, revision) = try database.read { db in
            let activeCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory WHERE archived = 0") ?? 0
            let archivedCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory WHERE archived = 1") ?? 0
            let dormantIDs = try String.fetchAll(db, sql: """
                SELECT id FROM memory WHERE archived = 0 AND hit_count = 0 AND updated < ?
                ORDER BY updated, id LIMIT 50
                """, arguments: [cutoff])
            let revision = try Self.vectorRevision(db)
            duplicatePairsLock.lock()
            let cached = duplicatePairsCache
            duplicatePairsLock.unlock()
            if let cached, cached.revision == revision {
                return (activeCount, archivedCount, dormantIDs, Optional(cached.pairs),
                        [(id: String, vector: [Float])](), revision)
            }
            let vectors = try activeVectors(db)
            let ids = try String.fetchCursor(db, sql: """
                SELECT id FROM memory WHERE archived = 0 AND vectors IS NOT NULL ORDER BY updated DESC, id
                """)
            var candidates: [(id: String, vector: [Float])] = []
            while candidates.count < 512, let id = try ids.next() {
                if let vector = vectors[id] { candidates.append((id, vector)) }
            }
            return (activeCount, archivedCount, dormantIDs, nil, candidates, revision)
        }
        let pairs = cachedPairs ?? calculateDuplicatePairs(candidates, revision: revision)
        return MemoryHealthSummary(activeCount: activeCount, archivedCount: archivedCount,
                                   duplicatePairs: pairs, dormantMemoryIDs: dormantIDs)
    }

    private func calculateDuplicatePairs(_ candidates: [(id: String, vector: [Float])],
                                         revision: Int64) -> [MemoryHealthSummary.DuplicatePair] {
        var pairs: [MemoryHealthSummary.DuplicatePair] = []
        for (index, first) in candidates.enumerated() {
            for second in candidates.dropFirst(index + 1) {
                let similarity = Retrieval.similarity(first.vector, second.vector)
                guard similarity >= Retrieval.duplicateThreshold else { continue }
                pairs.append(.init(memoryAID: min(first.id, second.id), memoryBID: max(first.id, second.id),
                                   similarity: similarity))
            }
        }
        pairs.sort {
            if $0.similarity != $1.similarity { return $0.similarity > $1.similarity }
            if $0.memoryAID != $1.memoryAID { return $0.memoryAID < $1.memoryAID }
            return $0.memoryBID < $1.memoryBID
        }
        let result = Array(pairs.prefix(50))
        duplicatePairsLock.lock()
        if duplicatePairsCache.map({ $0.revision <= revision }) ?? true {
            duplicatePairsCache = (revision, result)
        }
        duplicatePairsLock.unlock()
        return result
    }

    @discardableResult
    public func repairVectors() throws -> Bool {
        guard EmbeddingRuntime.isInstalled() else { return false }
        let missing = try database.read { db in
            let vectors = try activeVectors(db)
            let rows = try Row.fetchCursor(db, sql: "SELECT id, payload FROM memory WHERE archived = 0")
            var pending: [Memory] = []
            while let row = try rows.next() {
                guard vectors[row["id"] as String] == nil else { continue }
                pending.append(try Wire.decode(Memory.self, row["payload"]))
            }
            return pending
        }
        if missing.isEmpty { return true }
        guard !Retrieval.vectors("记忆 search").isEmpty else { return false }
        var updates: [(id: String, version: Int, data: Data)] = []
        for memory in missing {
            let vectors = Retrieval.vectors(memory.title + "\n" + memory.body)
            guard !vectors.isEmpty else { continue }
            updates.append((memory.id, memory.version, try Wire.data(vectors)))
        }
        try database.write { db in
            for update in updates {
                try db.execute(sql: """
                    UPDATE memory SET vectors = ? WHERE id = ? AND content_version = ? AND archived = 0
                    """, arguments: [update.data, update.id, update.version])
            }
        }
        return try database.read { db in
            let active = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory WHERE archived = 0") ?? 0
            return try activeVectors(db).count == active
        }
    }

    private static func releaseExpired(_ db: Database) throws {
        try db.execute(sql: """
            UPDATE evidence SET state = 'queued' WHERE state = 'claimed' AND id IN (
              SELECT be.evidence_id FROM batch_evidence be JOIN batch b ON b.id = be.batch_id
              WHERE b.expires < ? AND b.response IS NULL
            ) AND id NOT IN (
              SELECT be.evidence_id FROM batch_evidence be JOIN batch b ON b.id = be.batch_id
              WHERE b.expires >= ? AND b.response IS NULL
            )
            """, arguments: [Date().timeIntervalSince1970, Date().timeIntervalSince1970])
    }

    func releaseUndeliveredBatch(_ id: String) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE batch SET expires = 0 WHERE id = ? AND response IS NULL", arguments: [id])
            try Self.releaseExpired(db)
        }
    }

    public func getBatch(project: String? = nil, limit: Int = 4, batchID: String? = nil,
                         through: Int64? = nil) throws -> DreamBatch? {
        try database.write { db in
            try Self.releaseExpired(db)
            if let batchID {
                guard let row = try Row.fetchOne(db, sql: "SELECT expires,payload,response FROM batch WHERE id = ?",
                                                arguments: [batchID]) else { throw MemoryError.invalid("找不到做梦批次。") }
                let response: Data? = row["response"]
                let expires: Double = row["expires"]
                guard response == nil, expires >= Date().timeIntervalSince1970 else {
                    throw MemoryError.invalid("批次已提交或已过期。")
                }
                let batch = try Wire.decode(DreamBatch.self, row["payload"])
                for evidence in batch.evidence {
                    guard try String.fetchOne(db, sql: "SELECT state FROM evidence WHERE id = ?", arguments: [evidence.id]) == "claimed" else {
                        throw MemoryError.invalid("批次含已排除来源，请重新领取。")
                    }
                }
                return batch
            }
            let limit = min(max(1, limit), 8)
            var sql = "SELECT payload FROM evidence WHERE state = 'queued'"
            var arguments: StatementArguments = []
            if let project {
                sql += " AND project = ?"
                arguments += [ProjectIdentity.resolve(project)]
            }
            if let through {
                sql += " AND rowid <= ?"
                arguments += [through]
            }
            sql += " ORDER BY time, rowid LIMIT ?"
            arguments += [limit]
            let payloads = try Data.fetchAll(db, sql: sql, arguments: arguments)
            let evidence = try payloads.map { try Wire.decode(Evidence.self, $0) }
            guard !evidence.isEmpty else { return nil }
            var related: [Memory] = []
            var seen: Set<String> = []
            for item in evidence {
                let hits = try search(db, item.excerpt, scope: .projectAndGlobal(item.project), limit: 3).hits
                for hit in hits where seen.insert(hit.id).inserted { related.append(hit.memory) }
            }
            let createdAt = Date().timeIntervalSince1970
            let batch = DreamBatch(batchID: "dream-" + UUID().uuidString.lowercased(), evidence: evidence,
                                   relatedMemories: Array(related.prefix(6)), expires: createdAt + 1800)
            try db.execute(sql: "INSERT INTO batch (id,expires,payload,created_at) VALUES (?,?,?,?)",
                           arguments: [batch.id, batch.expires, try Wire.data(batch), createdAt])
            for item in evidence {
                try db.execute(sql: "INSERT INTO batch_evidence VALUES (?,?)", arguments: [batch.id, item.id])
                try db.execute(sql: "UPDATE evidence SET state = 'claimed' WHERE id = ?", arguments: [item.id])
            }
            try Self.insertActivity(db, .dreamClaim, project: project.map(ProjectIdentity.resolve),
                                    count: evidence.count, batchID: batch.id)
            return batch
        }
    }

    public func submit(batchID: String, proposals: [Proposal]) throws -> Submission {
        let request = try Wire.data(proposals)
        return try database.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM batch WHERE id = ?", arguments: [batchID]) else {
                throw MemoryError.invalid("找不到做梦批次。")
            }
            if let stored: Data = row["submission"], let response: Data = row["response"] {
                guard stored == request else { throw MemoryError.invalid("此批次已有不同的提交。") }
                return try Wire.decode(Submission.self, response)
            }
            let expires: Double = row["expires"]
            guard expires >= Date().timeIntervalSince1970 else { throw MemoryError.invalid("批次已过期，请重新领取。") }
            let batch = try Wire.decode(DreamBatch.self, row["payload"])
            guard !proposals.isEmpty, proposals.count <= 24 else { throw MemoryError.invalid("请提交 1–24 条提案。") }
            var targets: Set<String> = []
            var covered: Set<String> = []
            var decisions: [Decision] = []
            for proposal in proposals {
                try Self.validate(proposal, batch: batch, db: db)
                if let target = proposal.memoryID, !targets.insert(target).inserted {
                    throw MemoryError.invalid("同一批次只能对同一条记忆提交一项变更。")
                }
                covered.formUnion(proposal.evidenceIDs)
                let status = try status(proposal, db: db)
                let decision = Decision(id: UUID().uuidString, batchID: batchID, proposal: proposal,
                                        status: status.0, message: status.1)
                try db.execute(sql: "INSERT INTO decision VALUES (?,?,?,?)",
                               arguments: [decision.id, batchID, decision.status, try Wire.data(decision)])
                if status.0 == "applied" { try Self.apply(proposal, batchID: batchID, db: db) }
                decisions.append(decision)
            }
            let retry = Set(decisions.filter { $0.status == "conflict" }.flatMap { $0.proposal.evidenceIDs })
            let resolved = Set(decisions.filter { $0.status != "conflict" }.flatMap { $0.proposal.evidenceIDs })
            for evidence in batch.evidence {
                let complete = covered.contains(evidence.id) && (!retry.contains(evidence.id) || resolved.contains(evidence.id))
                try db.execute(sql: "UPDATE evidence SET state = ? WHERE id = ? AND state = 'claimed'",
                               arguments: [complete ? "done" : "queued", evidence.id])
            }
            let result = Submission(batchID: batchID, decisions: decisions)
            try db.execute(sql: "UPDATE batch SET submission = ?, response = ? WHERE id = ?",
                           arguments: [request, try Wire.data(result), batchID])
            try Self.insertActivity(db, .dreamSubmit, count: decisions.count, batchID: batchID)
            return result
        }
    }

    private static func validate(_ proposal: Proposal, batch: DreamBatch, db: Database) throws {
        guard !proposal.evidenceIDs.isEmpty, Set(proposal.evidenceIDs).count == proposal.evidenceIDs.count,
              !proposal.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              proposal.reason.count <= 800 else { throw MemoryError.invalid("每项提案需要证据和简短理由。") }
        let valid = Dictionary(uniqueKeysWithValues: batch.evidence.map { ($0.id, $0) })
        for id in proposal.evidenceIDs {
            guard valid[id] != nil, try String.fetchOne(db, sql: "SELECT state FROM evidence WHERE id = ?",
                                                        arguments: [id]) == "claimed" else {
                throw MemoryError.invalid("证据不属于当前批次，或来源已排除。")
            }
        }
        let content = [proposal.title, proposal.body, proposal.project, proposal.reason].compactMap { $0 }.joined(separator: "\n")
        guard !SecretFilter.contains(content) else { throw MemoryError.invalid("提案包含疑似凭据，未能保存。") }
        if proposal.operation == .skip {
            guard proposal.memoryID == nil, proposal.expectedVersion == nil, proposal.scope == nil,
                  proposal.project == nil, proposal.title == nil, proposal.body == nil else {
                throw MemoryError.invalid("跳过仅需证据和理由。")
            }
            return
        }
        if proposal.operation == .add || proposal.operation == .update {
            guard let title = proposal.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 120,
                  let body = proposal.body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, body.count <= 2200 else {
                throw MemoryError.invalid("新增或更新需要有效标题和正文。")
            }
            if proposal.scope == "project" {
                guard let project = proposal.project,
                      proposal.evidenceIDs.allSatisfy({ valid[$0]?.project == project }) else {
                    throw MemoryError.invalid("项目记忆只能引用同项目证据。")
                }
            } else if proposal.scope != "global" || proposal.project != nil {
                throw MemoryError.invalid("请提供有效的项目或全局范围。")
            }
        }
        if proposal.operation == .update || proposal.operation == .archive {
            guard let target = proposal.memoryID,
                  let previous = batch.relatedMemories.first(where: { $0.id == target }),
                  proposal.expectedVersion == previous.version else {
                throw MemoryError.invalid("目标记忆及预期版本必须来自当前批次。")
            }
            if previous.project != nil {
                guard proposal.evidenceIDs.allSatisfy({ valid[$0]?.project == previous.project }),
                      proposal.scope != "project" || proposal.project == previous.project else {
                    throw MemoryError.invalid("不能用无关项目的证据修改记忆。")
                }
            } else if proposal.scope == "project" {
                throw MemoryError.invalid("全局记忆不可直接转为项目记忆。")
            }
        } else if proposal.memoryID != nil || proposal.expectedVersion != nil {
            throw MemoryError.invalid("新增提案不接受目标记忆。")
        }
    }

    private func status(_ proposal: Proposal, db: Database) throws -> (String, String) {
        if proposal.operation == .skip { return ("skipped", proposal.reason) }
        if let id = proposal.memoryID {
            guard let current = try Self.current(db, id), current.version == proposal.expectedVersion, !current.archived else {
                return ("conflict", "旧版本已变化，请重新领取对应证据。")
            }
        }
        if proposal.operation == .archive || proposal.scope == "global" { return ("review", "需要确认范围或归档。") }
        if let title = proposal.title {
            let scope = proposal.project.map(SearchScope.projectAndGlobal) ?? .all
            let hits = try search(db, title + "\n" + (proposal.body ?? ""), scope: scope, limit: 15,
                                  cacheVectors: false).hits
            if hits.contains(where: {
                $0.id != proposal.memoryID && ($0.memory.title.caseInsensitiveCompare(title) == .orderedSame ||
                    ($0.vector ?? 0) >= 0.86)
            }) {
                return ("review", "发现相似记忆，请确认是否重复。")
            }
        }
        return ("applied", "已写回记忆库。")
    }

    /// Latest persisted record by default. Pass a version to read a snapshot for a dream proposal.
    public func memory(id: String, version: Int? = nil) throws -> Memory? {
        try database.read { db in
            let current = try Self.current(db, id)
            guard let version, version != current?.version else { return current }
            let snapshot = try Data.fetchOne(db, sql: """
                SELECT current FROM history WHERE memory_id = ?
                AND json_extract(CAST(current AS TEXT), '$.version') = ? ORDER BY id DESC LIMIT 1
                """, arguments: [id, version])
            return try snapshot.map { try Wire.decode(Memory.self, $0) }
        }
    }

    private static func memory(_ row: Row) throws -> Memory {
        var memory = try Wire.decode(Memory.self, row["payload"])
        memory.hitCount = row["hit_count"]
        memory.lastHitAt = row["last_hit_at"]
        return memory
    }

    private static func current(_ db: Database, _ id: String) throws -> Memory? {
        try Row.fetchOne(db, sql: "SELECT payload, hit_count, last_hit_at FROM memory WHERE id = ?",
                         arguments: [id]).map(memory)
    }

    private static func apply(_ proposal: Proposal, batchID: String, db: Database) throws {
        let previous = try proposal.memoryID.flatMap { try current(db, $0) }
        if let target = proposal.memoryID {
            guard let previous, previous.id == target, previous.version == proposal.expectedVersion, !previous.archived else {
                throw MemoryError.invalid("记忆在确认期间已经修改。")
            }
        }
        let isArchive = proposal.operation == .archive
        let ids = Array(Set((previous?.evidenceIDs ?? []) + proposal.evidenceIDs)).sorted()
        let memory = Memory(id: previous?.id ?? UUID().uuidString, version: (previous?.version ?? 0) + 1,
                            title: isArchive ? (previous?.title ?? "") : (proposal.title ?? ""),
                            body: isArchive ? (previous?.body ?? "") : (proposal.body ?? ""),
                            project: isArchive ? previous?.project : proposal.project,
                            archived: isArchive, evidenceIDs: ids, updated: Date().timeIntervalSince1970)
        try save(db, memory: memory, previous: previous, batchID: batchID)
    }

    private static func save(_ db: Database, memory: Memory, previous: Memory?, batchID: String) throws {
        let vectors = memory.archived ? [] : Retrieval.vectors(memory.title + "\n" + memory.body)
        let encoded = try Wire.data(memory)
        let vectorData = vectors.isEmpty ? nil : try Wire.data(vectors)
        try db.execute(sql: """
            INSERT INTO memory (id, project, archived, updated, payload, vectors, content_version) VALUES (?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET project=excluded.project, archived=excluded.archived, updated=excluded.updated,
                payload=excluded.payload, vectors=excluded.vectors, content_version=excluded.content_version
            """, arguments: [memory.id, memory.project, memory.archived, memory.updated, encoded, vectorData, memory.version])
        try db.execute(sql: "DELETE FROM memory_fts WHERE id = ?", arguments: [memory.id])
        if !memory.archived {
            try db.execute(sql: "INSERT INTO memory_fts (id,title,body) VALUES (?,?,?)",
                           arguments: [memory.id, Retrieval.indexText(memory.title), Retrieval.indexText(memory.body)])
        }
        try db.execute(sql: "INSERT INTO history (memory_id,batch_id,previous,current) VALUES (?,?,?,?)",
                       arguments: [memory.id, batchID, try previous.map(Wire.data), encoded])
    }

    public func review(_ decisionID: String, accept: Bool) throws {
        try database.write { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM decision WHERE id = ? AND status = 'review'",
                                               arguments: [decisionID]) else { throw MemoryError.invalid("找不到待确认提案。") }
            let decision = try Wire.decode(Decision.self, data)
            guard try Int.fetchOne(db, sql: "SELECT reversed FROM batch WHERE id = ?", arguments: [decision.batchID]) == 0 else {
                throw MemoryError.invalid("该批次已撤销。")
            }
            if accept { try Self.apply(decision.proposal, batchID: decision.batchID, db: db) }
            try Self.setDecision(db, decision, status: accept ? "applied" : "rejected", message: accept ? "已确认写回。" : "已拒绝。")
        }
    }

    private static func setDecision(_ db: Database, _ decision: Decision, status: String, message: String) throws {
        let updated = Decision(id: decision.id, batchID: decision.batchID, proposal: decision.proposal, status: status, message: message)
        try db.execute(sql: "UPDATE decision SET status = ?, payload = ? WHERE id = ?",
                       arguments: [status, try Wire.data(updated), decision.id])
    }

    public func undo(_ batchID: String) throws {
        try database.write { db in
            guard try Int.fetchOne(db, sql: "SELECT reversed FROM batch WHERE id = ? AND response IS NOT NULL",
                                   arguments: [batchID]) == 0 else { throw MemoryError.invalid("找不到可撤销的批次。") }
            let items = try Row.fetchAll(db, sql: "SELECT * FROM history WHERE batch_id = ? ORDER BY id DESC",
                                         arguments: [batchID]).map(Self.historyItem)
            for item in items {
                guard let recent = try Self.current(db, item.current.id), recent.version == item.current.version else {
                    throw MemoryError.invalid("批次中的记忆已被更新，未撤销任何条目。")
                }
                let old = item.previous ?? recent
                let reversed = Memory(id: recent.id, version: recent.version + 1, title: old.title, body: old.body,
                                      project: old.project, archived: item.previous == nil || old.archived,
                                      evidenceIDs: old.evidenceIDs, updated: Date().timeIntervalSince1970)
                try Self.save(db, memory: reversed, previous: recent, batchID: "undo-" + batchID)
            }
            for data in try Data.fetchAll(db, sql: "SELECT payload FROM decision WHERE batch_id = ? AND status = 'review'",
                                          arguments: [batchID]) {
                try Self.setDecision(db, Wire.decode(Decision.self, data), status: "rejected", message: "批次已撤销。")
            }
            try db.execute(sql: "UPDATE batch SET reversed = 1 WHERE id = ?", arguments: [batchID])
            try Self.insertActivity(db, .dreamRollback, count: items.count, batchID: batchID)
        }
    }
}
