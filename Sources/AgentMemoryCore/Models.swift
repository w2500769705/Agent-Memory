import Foundation

public enum MemoryError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

public enum MemoryPaths {
    public static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AgentMemory", isDirectory: true)
    public static let socket = directory.appendingPathComponent("mcp.sock")
}

public struct Evidence: Codable, Identifiable, Sendable {
    public let id: String
    public let threadID: String
    public let turnID: String
    public let project: String
    public let timestamp: Double
    public let excerpt: String

    public init(id: String, threadID: String, turnID: String, project: String, timestamp: Double, excerpt: String) {
        self.id = id
        self.threadID = threadID
        self.turnID = turnID
        self.project = project
        self.timestamp = timestamp
        self.excerpt = excerpt
    }
}

public struct Memory: Codable, Identifiable, Sendable {
    public let id: String
    public let version: Int
    public let title: String
    public let body: String
    public let project: String?
    public let archived: Bool
    public let evidenceIDs: [String]
    public let updated: Double
    public internal(set) var hitCount: Int
    public internal(set) var lastHitAt: Double?
    public var scope: String { project == nil ? "global" : "project" }

    init(id: String, version: Int, title: String, body: String, project: String?, archived: Bool,
         evidenceIDs: [String], updated: Double) {
        self.id = id
        self.version = version
        self.title = title
        self.body = body
        self.project = project
        self.archived = archived
        self.evidenceIDs = evidenceIDs
        self.updated = updated
        self.hitCount = 0
        self.lastHitAt = nil
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        version = try values.decode(Int.self, forKey: .version)
        title = try values.decode(String.self, forKey: .title)
        body = try values.decode(String.self, forKey: .body)
        project = try values.decodeIfPresent(String.self, forKey: .project)
        archived = try values.decode(Bool.self, forKey: .archived)
        evidenceIDs = try values.decode([String].self, forKey: .evidenceIDs)
        updated = try values.decode(Double.self, forKey: .updated)
        hitCount = try values.decodeIfPresent(Int.self, forKey: .hitCount) ?? 0
        lastHitAt = try values.decodeIfPresent(Double.self, forKey: .lastHitAt)
    }
}

public struct SearchHit: Codable, Identifiable, Sendable {
    public var id: String { memory.id }
    public let memory: Memory
    public let vector: Double?
    public let keywordRank: Int?
    public let score: Double

    public init(memory: Memory, vector: Double?, keywordRank: Int?, score: Double) {
        self.memory = memory
        self.vector = vector
        self.keywordRank = keywordRank
        self.score = score
    }
}

public enum SearchScope: Equatable, Sendable {
    case all
    case global
    case project(String)
    case projectAndGlobal(String)
}

public struct SearchInspection: Sendable {
    public let hits: [SearchHit]
    public let filteredCandidates: [SearchHit]
    public let elapsedMs: Int
}

public struct MemoryHealthSummary: Equatable, Sendable {
    public struct DuplicatePair: Equatable, Sendable {
        public let memoryAID: String
        public let memoryBID: String
        public let similarity: Double
    }

    public let activeCount: Int
    public let archivedCount: Int
    public let duplicatePairs: [DuplicatePair]
    public let dormantMemoryIDs: [String]

    public init(activeCount: Int = 0, archivedCount: Int = 0,
                duplicatePairs: [DuplicatePair] = [], dormantMemoryIDs: [String] = []) {
        self.activeCount = activeCount
        self.archivedCount = archivedCount
        self.duplicatePairs = duplicatePairs
        self.dormantMemoryIDs = dormantMemoryIDs
    }
}

public struct MemoryGraph: Equatable, Sendable {
    public let nodes: [MemoryGraphNode]
    public let edges: [MemoryGraphEdge]
    public let generatedAt: Date

    public init(nodes: [MemoryGraphNode] = [], edges: [MemoryGraphEdge] = [], generatedAt: Date = .distantPast) {
        self.nodes = nodes
        self.edges = edges
        self.generatedAt = generatedAt
    }
}

public struct MemoryGraphNode: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let scope: String
    public let project: String?
    public let hitCount: Int
    public let updated: Double
    public let freshness: Double
    public let evidenceCount: Int
    public let isDormant: Bool
}

public struct MemoryGraphEdge: Equatable, Identifiable, Sendable {
    public enum Kind: String, Sendable {
        case semantic, duplicate, sharedEvidence
    }

    public let id: String
    public let sourceID: String
    public let targetID: String
    public let kind: Kind
    public let weight: Double

    init(_ firstID: String, _ secondID: String, kind: Kind, weight: Double) {
        sourceID = min(firstID, secondID)
        targetID = max(firstID, secondID)
        id = "\(kind.rawValue):\(sourceID):\(targetID)"
        self.kind = kind
        self.weight = weight
    }
}

public enum Operation: String, Codable, Sendable { case add, update, archive, skip }

public struct Proposal: Codable, Sendable {
    public let operation: Operation
    public let evidenceIDs: [String]
    public let reason: String
    public let scope: String?
    public let project: String?
    public let title: String?
    public let body: String?
    public let memoryID: String?
    public let expectedVersion: Int?

    public init(operation: Operation, evidenceIDs: [String], reason: String, scope: String? = nil,
                project: String? = nil, title: String? = nil, body: String? = nil,
                memoryID: String? = nil, expectedVersion: Int? = nil) {
        self.operation = operation
        self.evidenceIDs = evidenceIDs
        self.reason = reason
        self.scope = scope
        self.project = project
        self.title = title
        self.body = body
        self.memoryID = memoryID
        self.expectedVersion = expectedVersion
    }
}

public struct DreamBatch: Codable, Identifiable, Sendable {
    public var id: String { batchID }
    public let batchID: String
    public let evidence: [Evidence]
    public let relatedMemories: [Memory]
    public let expires: Double
}

public struct Decision: Codable, Identifiable, Sendable {
    public let id: String
    public let batchID: String
    public let proposal: Proposal
    public let status: String
    public let message: String
}

public struct Submission: Codable, Sendable {
    public let batchID: String
    public let decisions: [Decision]
}

public struct HistoryItem: Identifiable, Sendable {
    public let id: Int64
    public let batchID: String
    public let previous: Memory?
    public let current: Memory
}

public struct DreamBatchSummary: Identifiable, Sendable {
    public var id: String { batchID }
    public let batchID: String
    public let createdAt: Double
    public let appliedCount: Int
    public let pendingCount: Int
    public let conflictCount: Int
    public let canRollback: Bool
}

public struct Dashboard: Sendable {
    public let memories: Int
    public let pending: Int
    public let queuedThrough: Int64?
    public let review: Int
    public let evidence: [Evidence]
    public let decisions: [Decision]
    public let batches: [String]
    public let batchSummaries: [DreamBatchSummary]
}

public struct ProjectSummary: Codable, Sendable, Equatable {
    public let project: String
    public let activeMemoryCount: Int
    public let archivedMemoryCount: Int
    public let queuedEvidenceCount: Int
    public let claimedEvidenceCount: Int
}

public struct ProjectMigrationPreview: Codable, Sendable, Equatable {
    public let fromProject: String
    public let toProject: String
    public let activeMemoryCount: Int
    public let archivedMemoryCount: Int
    public let queuedEvidenceCount: Int
    public let doneEvidenceCount: Int
    public let claimedEvidenceCount: Int
}

public struct ProjectMigrationResult: Codable, Sendable, Equatable {
    public let fromProject: String
    public let toProject: String
    public let migratedMemoryCount: Int
    public let migratedEvidenceCount: Int
}

public struct ActivityEvent: Identifiable, Sendable {
    public enum Kind: String, Sendable {
        case scan, recall, search, error
        case dreamClaim = "dream_claim"
        case dreamSubmit = "dream_submit"
        case dreamRollback = "dream_rollback"
    }

    public enum Agent: String, Sendable {
        case codex, antigravity
    }

    public let id: Int64
    public let kind: Kind
    public let timestamp: Date
    public let agent: Agent?
    public let project: String?
    public let memoryIDs: [String]
    public let count: Int?
    public let estimatedTokens: Int?
    public let batchID: String?
    public let message: String?
}

public struct RuntimeHealth: Equatable, Sendable {
    public enum CaptureState: Equatable, Sendable {
        case unavailable, paused, idle, scanning, failed
    }

    public enum EmbeddingState: Equatable, Sendable {
        case checking, indexing, ready, unavailable, failed
    }

    public let codexCapture: CaptureState
    public let antigravityCapture: CaptureState
    public let embedding: EmbeddingState
    public let codexLastScan: Date?
    public let antigravityLastScan: Date?

    public init(codexCapture: CaptureState = .unavailable, antigravityCapture: CaptureState = .unavailable,
                embedding: EmbeddingState = .checking, codexLastScan: Date? = nil,
                antigravityLastScan: Date? = nil) {
        self.codexCapture = codexCapture
        self.antigravityCapture = antigravityCapture
        self.embedding = embedding
        self.codexLastScan = codexLastScan
        self.antigravityLastScan = antigravityLastScan
    }
}

public enum Wire {
    public static func data<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    public static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

enum SecretFilter {
    private static let regex = try! NSRegularExpression(pattern: #"(?i)(-----BEGIN [^-\r\n]*PRIVATE KEY-----|(?:sk-(?:proj-)?|sk-ant-|gh[pousr]_|github_pat_|xox[baprs]-|AKIA)[a-z0-9_-]{12,}|Bearer\s+[a-z0-9_.+/=-]{12,}|(?:[a-z][a-z0-9+.-]*://)[^\s/@:]+:[^\s/@]+@|(?:password|passwd|api[_ -]?key|secret[_ -]?key|access[_ -]?token|密码|密钥)\s*[:=：]\s*["']?[^\s"',;，。]{6,})"#)
    static func contains(_ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

public enum ProjectIdentity {
    public static func resolve(_ path: String) -> String {
        guard path.hasPrefix("/") else { return "" }
        let original = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        var directory = original
        while directory.path != "/" {
            let git = directory.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: git.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue { return directory.path }
                if let marker = try? String(contentsOf: git, encoding: .utf8), marker.hasPrefix("gitdir: ") {
                    let value = marker.dropFirst(8).trimmingCharacters(in: .whitespacesAndNewlines)
                    let repo = URL(fileURLWithPath: value, relativeTo: directory.appendingPathComponent("", isDirectory: true)).standardizedFileURL
                    if let common = try? String(contentsOf: repo.appendingPathComponent("commondir"), encoding: .utf8) {
                        let commonURL = URL(fileURLWithPath: common.trimmingCharacters(in: .whitespacesAndNewlines),
                                            relativeTo: repo.appendingPathComponent("", isDirectory: true)).standardizedFileURL
                        if commonURL.lastPathComponent == ".git" { return commonURL.deletingLastPathComponent().path }
                    }
                }
                return directory.path
            }
            directory.deleteLastPathComponent()
        }
        return original.path
    }
}
