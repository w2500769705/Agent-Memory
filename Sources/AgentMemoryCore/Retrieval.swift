import Accelerate
import Foundation

enum Retrieval {
    struct Vector: Codable {
        let model: String
        let values: [Float]
    }

    static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var latin = ""
        var han: [Character] = []
        func flushLatin() {
            if !latin.isEmpty { tokens.append(latin.lowercased()); latin = "" }
        }
        func flushHan() {
            for (index, character) in han.enumerated() {
                tokens.append(String(character))
                if index + 1 < han.count { tokens.append(String(han[index...index + 1])) }
            }
            han.removeAll()
        }
        for character in text {
            let scalar = character.unicodeScalars.first?.value ?? 0
            if (0x3400...0x9fff).contains(scalar) {
                flushLatin()
                han.append(character)
            } else {
                flushHan()
                if character.isLetter || character.isNumber { latin.append(character) }
                else { flushLatin() }
            }
        }
        flushLatin()
        flushHan()
        return tokens
    }

    static func indexText(_ text: String) -> String { tokens(text).joined(separator: " ") }

    static func phrase(_ query: String) -> String {
        var seen: Set<String> = []
        return ftsPhrase(tokens(query).filter { seen.insert($0).inserted })
    }

    private static func ftsPhrase(_ terms: [String]) -> String {
        terms.prefix(64)
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            .joined(separator: " OR ")
    }

    private static let recallStopWords = Set("""
        about again all also am an and any are as at be been being both but by can could did do does doing done
        each either else end for from get getting go going got had has have having here how if in into is it its
        just keep let like may me might more most much must my new next no nor now of off on one only or other
        our out over please re same see she should so some such take than that the their them then there these
        they this those through to too up us very via was we well were what when where which while who why will
        with within without would yet you your can’t can't don’t don't isn’t isn't won’t won't
        add already app application back before change check continue current currently default existing feature fine
        first help last latest later main make mode move need okay open original problem put result right run set
        setting settings show start state status still stop switch test thing time try update use used user using
        want way window windows work working works
        """.split(whereSeparator: \.isWhitespace).map(String.init))

    private static let recallHanStopWords = try! NSRegularExpression(pattern: """
        两边 那边 这边 两端 兩邊 那邊 這邊 兩端 双方 雙方 是否需要 要不要 能不能 可不可以 需不需要 新开 新開 打开 打開 关闭 關閉 窗口 视窗 視窗
        目前 现在 現在 当前 當前 之前 之后 之後 已经 已經 仍然 可能 应该 應該 没有 沒有 可以 继续 繼續 使用 设置 設置 状态 狀態
        还是 還是 或者 以及 而且 但是 如果 因为 因為 所以 然后 然後 是否 需要 不用 另外 同时 同時 有关 有關
        原有 原来 原來 已有 现有 現有 会话 會話 对话 對話 聊天 这些 這些 那些 这个 這個 那个 那個 这里 這裡 那里 那裡
        什么 什麼 怎么 怎麼 如何 怎样 怎樣 哪个 哪個 哪些 为什么 為什麼 一下 看看 帮我 幫我 我们 我們 你们 你們
        相关 相關 具体 具體 内容 內容 问题 問題 方式 情况 情況 处理 處理 操作 进行 進行 完成 开始 開始 结束 結束
        支持 功能 默认 預設 调整 調整 修改 更新 新增 确认 確認 检查 檢查 查看 等待 选择 選擇 结果 結果
        """.split(whereSeparator: \.isWhitespace).joined(separator: "|"))

    private static let recallTermPattern = try! NSRegularExpression(pattern:
        #"[\u3400-\u9fff]+|(?:~?/|\.{1,2}/)?[\p{Latin}\p{Nd}]+(?:[._/'’\-][\p{Latin}\p{Nd}]+)*|(?:(?![\u3400-\u9fff])[\p{L}\p{N}])+"#)

    static func recallTerms(_ text: String) -> Set<String> {
        // Mask whole stop phrases before forming bigrams so their boundaries do not become matches.
        let filtered = recallHanStopWords.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                                    withTemplate: " ")
        var result: Set<String> = []
        recallTermPattern.enumerateMatches(in: filtered, range: NSRange(filtered.startIndex..., in: filtered)) { match, _, _ in
            guard let match, let range = Range(match.range, in: filtered) else { return }
            let term = filtered[range].lowercased()
            if let first = term.unicodeScalars.first, (0x3400...0x9fff).contains(first.value) {
                result.formUnion(tokens(term).filter { $0.count == 2 })
            } else if term.count >= 2, !recallStopWords.contains(term) {
                result.insert(term)
            }
        }
        return result
    }

    static func isTechnicalTerm(_ term: String) -> Bool {
        term.unicodeScalars.allSatisfy(\.isASCII) && term.filter { $0.isLetter || $0.isNumber }.count >= 3
    }

    static func recallPhrase(_ terms: Set<String>) -> String {
        // The existing FTS index splits punctuation. Match a path or version as an indexed phrase.
        ftsPhrase(terms.sorted().map(indexText))
    }

    static let currentModelID = "minilm-multilingual-l12-faf4aa42-fastembed-0.9.1:384"

    static func vectors(_ text: String) -> [Vector] {
        LocalEmbeddings.shared.encode(String(text.prefix(900)))
    }

    static let dimensions = 384
    static let vectorThreshold = 0.34
    static let inspectionThreshold = 0.28
    static let duplicateThreshold = 0.90

    static func currentVector(from vectors: [Vector]) -> [Float]? {
        vectors.first { $0.model == currentModelID && $0.values.count == dimensions && $0.values.allSatisfy(\.isFinite) }?.values
    }

    static func similarity(_ lhs: [Float], _ rhs: [Float]) -> Double {
        var dot: Float = 0
        vDSP_dotpr(lhs, 1, rhs, 1, &dot, vDSP_Length(dimensions))
        guard dot.isFinite else { return -1 }
        return min(1, max(-1, Double(dot)))
    }
}

public enum EmbeddingRuntime {
    public static let defaultIdleTimeout: TimeInterval = 300

    public static func isInstalled() -> Bool {
        LocalEmbeddings.shared.isInstalled()
    }

    public static func isRunning() -> Bool {
        LocalEmbeddings.shared.isRunning()
    }

    public static func setIdleTimeout(_ seconds: TimeInterval?) {
        LocalEmbeddings.shared.setIdleTimeout(seconds)
    }

    public static func shutdown() {
        LocalEmbeddings.shared.shutdown()
    }
}

private final class LocalEmbeddings: @unchecked Sendable {
    static let shared = LocalEmbeddings()
    private let lock = NSLock()
    private let idleQueue = DispatchQueue(label: "agent.memory.embedding.idle")
    private var worker: LineProcess?
    private var idleWorkItem: DispatchWorkItem?
    private var idleTimeout: TimeInterval? = EmbeddingRuntime.defaultIdleTimeout
    private var lastUsedAt = Date.distantPast
    private var retryAfter = Date.distantPast
    private var cache: [String: [Retrieval.Vector]] = [:]
    private let model = Retrieval.currentModelID

    private struct Request: Encodable { let texts: [String] }
    private struct Response: Decodable { let vectors: [[Float]] }

    private static func runtimePaths() -> (executable: URL, script: URL, models: URL) {
        let root = ProcessInfo.processInfo.environment["AGENT_MEMORY_EMBEDDING_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? MemoryPaths.directory.appendingPathComponent("Embedding")
        return (
            root.appendingPathComponent("runtime/bin/python"),
            root.appendingPathComponent("worker.py"),
            root.appendingPathComponent("models")
        )
    }

    func isInstalled() -> Bool {
        let paths = Self.runtimePaths()
        return FileManager.default.isExecutableFile(atPath: paths.executable.path) &&
            FileManager.default.fileExists(atPath: paths.script.path)
    }

    func isRunning() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return worker != nil
    }

    func setIdleTimeout(_ seconds: TimeInterval?) {
        lock.lock()
        idleTimeout = seconds.map { max(1, $0) }
        if worker != nil {
            scheduleIdleCheckLocked()
        } else {
            idleWorkItem?.cancel()
            idleWorkItem = nil
        }
        lock.unlock()
    }

    func shutdown() {
        lock.lock()
        idleWorkItem?.cancel()
        idleWorkItem = nil
        worker = nil
        lock.unlock()
    }

    private func scheduleIdleCheckLocked() {
        idleWorkItem?.cancel()
        idleWorkItem = nil
        guard let timeout = idleTimeout, worker != nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.evictIfIdle()
        }
        idleWorkItem = work
        idleQueue.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    private func evictIfIdle() {
        lock.lock()
        defer { lock.unlock() }
        guard let timeout = idleTimeout, worker != nil else { return }
        let elapsed = Date().timeIntervalSince(lastUsedAt)
        if elapsed >= timeout - 0.05 {
            worker = nil
            idleWorkItem = nil
        } else {
            let remaining = max(0.5, timeout - elapsed)
            let work = DispatchWorkItem { [weak self] in
                self?.evictIfIdle()
            }
            idleWorkItem = work
            idleQueue.asyncAfter(deadline: .now() + remaining, execute: work)
        }
    }

    func encode(_ text: String) -> [Retrieval.Vector] {
        lock.lock()
        defer { lock.unlock() }
        if let vectors = cache[text] { return vectors }
        guard Date() >= retryAfter else { return [] }
        do {
            if worker == nil {
                let paths = Self.runtimePaths()
                guard FileManager.default.isExecutableFile(atPath: paths.executable.path) else { return [] }
                worker = try LineProcess(executable: paths.executable,
                    arguments: [paths.script.path, "--cache", paths.models.path],
                    name: "本地向量模型")
            }
            guard let worker else { return [] }
            lastUsedAt = Date()
            scheduleIdleCheckLocked()
            try worker.writeLine(Wire.data(Request(texts: [text])))
            let data = try worker.readLine(deadline: DispatchTime.now().uptimeNanoseconds + 8_000_000_000)
            lastUsedAt = Date()
            scheduleIdleCheckLocked()
            guard let values = try Wire.decode(Response.self, data).vectors.first, values.count == Retrieval.dimensions else { return [] }
            let norm = sqrt(values.reduce(Float(0)) { $0 + $1 * $1 })
            guard norm.isFinite, norm > 0 else { return [] }
            let vector = [Retrieval.Vector(model: model, values: values.map { $0 / norm })]
            if cache.count >= 75 { cache.removeAll(keepingCapacity: true) }
            cache[text] = vector
            return vector
        } catch {
            worker = nil
            idleWorkItem?.cancel()
            idleWorkItem = nil
            retryAfter = Date().addingTimeInterval(15)
            return []
        }
    }
}
