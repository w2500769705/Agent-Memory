import AgentMemoryCore
import AppKit
import Combine
import ServiceManagement
import SwiftUI

struct CopyToast: Equatable, Identifiable {
    let id = UUID()
    let message: String
}

enum CloseBehavior: String, CaseIterable, Identifiable {
    case ask = "ask"
    case minimizeToMenuBar = "menuBar"
    case quit = "quit"

    var id: Self { self }
    var label: String {
        switch self {
        case .ask: return "每次询问"
        case .minimizeToMenuBar: return "保留在状态栏"
        case .quit: return "彻底退出"
        }
    }
}

enum AppThemeMode: String, CaseIterable, Identifiable {
    case system, dark, light

    var id: Self { self }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var dashboard: Dashboard?
    @Published private(set) var recentActivities: [ActivityEvent] = []
    @Published private(set) var todayRecallCount: Int = 0
    @Published private(set) var todayRecallEstimatedTokens: Int = 0
    @Published private(set) var runtimeHealth = RuntimeHealth()
    @Published private(set) var healthSummary: MemoryHealthSummary = MemoryHealthSummary()
    @Published var hits: [SearchHit] = []
    @Published var evidence: [Evidence] = []
    @Published var history: [HistoryItem] = []
    @Published var previous: Memory?
    @Published var enabled = false
    @Published var antigravityEnabled = false
    @Published var login = false
    @Published var scanning = false
    @Published var antigravityScanning = false
    @Published var embeddingReady: Bool?
    @Published var lastScan: Date?
    @Published var antigravityLastScan: Date?
    @Published var status = ""
    @Published var antigravityStatus = ""
    @Published var error: String?
    @Published var copyToast: CopyToast?
    @Published var query = ""
    @Published var projectFilter = false
    @Published var project = ""
    @Published var excludedProjects: [String] = []
    @Published var excludedThreads: [String] = []
    @Published var selectedMemory: SearchHit?
    @Published var connection: CodexConnectionStatus?
    @Published var checkingConnection = false
    @Published var setupError: String?
    @Published var antigravityConnection: AntigravityConnectionStatus?
    @Published var checkingAntigravity = false
    @Published var antigravitySetupError: String?
    @Published var recallEnabled = false
    @Published var recallVerifiedAt: Date?
    @Published var antigravityRecallEnabled = false
    @Published var antigravityRecallVerifiedAt: Date?
    @Published var recallCrossProject = false
    @Published var smartCapture = true
    @Published var closeBehavior: CloseBehavior = .ask
    @Published var themeMode: AppThemeMode = .system {
        didSet {
            guard themeMode != oldValue, let store else { return }
            do { try store.setSetting("themeMode", themeMode.rawValue) }
            catch { self.error = error.localizedDescription }
        }
    }
    private(set) var store: MemoryStore?
    private var toolServer: LocalToolServer?
    private var polling: Task<Void, Never>?
    private var codexWatcher: DirectoryWatcher?
    private var antigravityWatcher: DirectoryWatcher?
    private var copyToastTask: Task<Void, Never>?
    private var wakeObserver: AnyCancellable?
    private var activeObserver: AnyCancellable?
    private var calendarDayObserver: AnyCancellable?
    private var codexScanFailed = false
    private var antigravityScanFailed = false
    private var embeddingState: RuntimeHealth.EmbeddingState = .checking
    private var applicationSocket: URL = MemoryPaths.socket

    init() {
        do {
            let environment = ProcessInfo.processInfo.environment
            let directory = environment["AGENT_MEMORY_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? MemoryPaths.directory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                  attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            store = try MemoryStore(path: directory.appendingPathComponent("memory.sqlite3").path)
            applicationSocket = directory.appendingPathComponent("mcp.sock")
            if let store {
                let savedTheme = try? store.setting("themeMode")
                _themeMode = Published(initialValue: savedTheme.flatMap(AppThemeMode.init(rawValue:)) ?? .system)
                toolServer = try LocalToolServer(
                    store: store,
                    path: applicationSocket,
                    beforeDream: {
                        _ = try? CodexSource.scan(store: store, force: false)
                        _ = try? AntigravitySource.scan(store: store)
                    },
                    onChange: { [weak self] in
                        Task { @MainActor in
                            self?.refresh()
                            if self?.embeddingReady != true {
                                await self?.refreshIndex()
                            }
                        }
                    }
                )
            }
        } catch {
            store = nil
            embeddingState = .unavailable
            updateRuntimeHealth()
            self.error = error.localizedDescription
            return
        }
        login = SMAppService.mainApp.status == .enabled
        refresh()
        verifyMissingAgentConnections()
        reconfigureScheduling(runInitialScan: true)
        wakeObserver = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.scan(force: false)
                    await self?.scanAntigravity()
                }
            }
        activeObserver = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.refreshActivities()
                    self.verifyMissingAgentConnections()
                    guard self.smartCapture else { return }
                    await self.scan(force: false)
                    await self.scanAntigravity()
                }
            }
        calendarDayObserver = NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshActivities() }
            }
    }

    private func reconfigureScheduling(runInitialScan: Bool = false) {
        polling?.cancel()
        polling = nil
        codexWatcher?.stop()
        codexWatcher = nil
        antigravityWatcher?.stop()
        antigravityWatcher = nil

        EmbeddingRuntime.setIdleTimeout(smartCapture ? EmbeddingRuntime.defaultIdleTimeout : nil)

        if smartCapture {
            if enabled {
                codexWatcher = DirectoryWatcher(
                    paths: [CodexSetup.home.path],
                    debounceSeconds: 15,
                    maxWaitSeconds: 60,
                    ignoredFilenames: ["config.toml", "hooks.json", "auth.json", "version.json", ".DS_Store"],
                    label: "agent.memory.fsevents.codex"
                ) { [weak self] in
                    Task { @MainActor in
                        await self?.scan(force: false)
                    }
                }
            }
            if antigravityEnabled {
                antigravityWatcher = DirectoryWatcher(
                    paths: AntigravitySource.defaultBrainDirectories.map(\.path),
                    debounceSeconds: 15,
                    maxWaitSeconds: 60,
                    ignoredFilenames: [".DS_Store"],
                    label: "agent.memory.fsevents.antigravity"
                ) { [weak self] in
                    Task { @MainActor in
                        await self?.scanAntigravity()
                    }
                }
            }
        }

        let isSmart = smartCapture
        let intervalSeconds = isSmart ? 900 : 30
        polling = Task { [weak self] in
            var firstTick = true
            while !Task.isCancelled {
                if firstTick && !runInitialScan {
                    firstTick = false
                    do { try await Task.sleep(for: .seconds(intervalSeconds)) }
                    catch { return }
                    continue
                }
                let shouldRunIndex = firstTick || self?.embeddingReady != true
                firstTick = false
                await self?.scan(force: !isSmart)
                await self?.scanAntigravity()
                if shouldRunIndex {
                    await self?.refreshIndex()
                }
                do { try await Task.sleep(for: .seconds(intervalSeconds)) }
                catch { return }
            }
        }
    }

    func refresh() {
        guard let store else { return }
        refreshActivities()
        refreshHealthSummary()
        defer { updateRuntimeHealth() }
        do {
            dashboard = try store.dashboard()
            enabled = try store.setting("enabled") == "1"
            antigravityEnabled = try store.setting(AntigravitySource.enabledKey) == "1"
            recallEnabled = try store.setting("recallEnabled") == "1"
            recallVerifiedAt = try store.setting("recallVerifiedAt").flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
            antigravityRecallEnabled = try store.setting("antigravityRecallEnabled") == "1"
            antigravityRecallVerifiedAt = try store.setting("antigravityRecallVerifiedAt").flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
            recallCrossProject = try store.setting(MemoryStore.recallCrossProjectKey) == "1"
            smartCapture = try store.isSmartCaptureEnabled()
            closeBehavior = (try store.setting("closeBehavior")).flatMap(CloseBehavior.init(rawValue:)) ?? .ask
            excludedProjects = (try store.setting("excludedProjects") ?? "").split(separator: "\n").map(String.init)
            excludedThreads = (try store.setting("excludedThreads") ?? "").split(separator: "\n").map(String.init)
            if let selectedMemory {
                let current = try store.memory(id: selectedMemory.id)
                if current?.version != selectedMemory.memory.version {
                    self.selectedMemory = nil
                    evidence = []
                    history = []
                } else if let current, current.hitCount != selectedMemory.memory.hitCount ||
                            current.lastHitAt != selectedMemory.memory.lastHitAt {
                    self.selectedMemory = SearchHit(memory: current, vector: selectedMemory.vector,
                                                    keywordRank: selectedMemory.keywordRank, score: selectedMemory.score)
                }
            }
            if searchTask == nil { find(recordActivity: false) }
            else { searchNeedsRefresh = true }
        } catch { self.error = error.localizedDescription }
    }

    func refreshActivities() {
        guard let store else { return }
        do {
            let activities = try store.recentActivities()
            let totals = try store.todayRecallTotals()
            recentActivities = activities
            todayRecallCount = totals.count
            todayRecallEstimatedTokens = totals.estimatedTokens
        } catch { self.error = error.localizedDescription }
    }

    private var healthTask: Task<Void, Never>?
    private var healthRefreshPending = false

    func refreshHealthSummary() {
        guard let store else { return }
        guard healthTask == nil else {
            healthRefreshPending = true
            return
        }
        healthTask = Task {
            defer {
                healthTask = nil
                if healthRefreshPending {
                    healthRefreshPending = false
                    refreshHealthSummary()
                }
            }
            do {
                let result = try await Task.detached(priority: .utility) { try store.memoryHealthSummary() }.value
                if result != healthSummary { healthSummary = result }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func inspectSearch(_ query: String, scope: SearchScope = .all, limit: Int = 20,
                       includeFilteredCandidates: Bool = false) async throws -> SearchInspection {
        guard let store else { throw MemoryError.invalid("记忆库未就绪。") }
        return try await Task.detached(priority: .userInitiated) {
            try store.inspectSearch(query, scope: scope, limit: limit, includeFilteredCandidates: includeFilteredCandidates)
        }.value
    }

    func memory(id: String, version: Int? = nil) throws -> Memory? {
        guard let store else { throw MemoryError.invalid("记忆库未就绪。") }
        return try store.memory(id: id, version: version)
    }

    func evidence(ids: [String]) throws -> [Evidence] {
        guard let store else { throw MemoryError.invalid("记忆库未就绪。") }
        return try store.evidence(ids)
    }

    private func updateRuntimeHealth() {
        func captureState(enabled: Bool, scanning: Bool, failed: Bool) -> RuntimeHealth.CaptureState {
            guard store != nil else { return .unavailable }
            guard enabled else { return .paused }
            if scanning { return .scanning }
            return failed ? .failed : .idle
        }
        let health = RuntimeHealth(
            codexCapture: captureState(enabled: enabled, scanning: scanning, failed: codexScanFailed),
            antigravityCapture: captureState(enabled: antigravityEnabled, scanning: antigravityScanning,
                                             failed: antigravityScanFailed),
            embedding: embeddingState,
            codexLastScan: lastScan, antigravityLastScan: antigravityLastScan
        )
        if runtimeHealth != health { runtimeHealth = health }
    }

    private var searchTask: Task<Void, Never>?
    private var searchNeedsRefresh = false

    func find() { find(recordActivity: true) }

    private func find(recordActivity: Bool) {
        searchTask?.cancel()
        searchNeedsRefresh = false
        guard let store else { return }
        let text = query
        let scope = projectFilter && project.hasPrefix("/") ? project : nil
        searchTask = Task {
            defer {
                if !Task.isCancelled {
                    searchTask = nil
                    if searchNeedsRefresh { find(recordActivity: false) }
                }
            }
            do {
                if recordActivity, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try await Task.sleep(for: .milliseconds(250))
                }
                let found = try await Task.detached {
                    try store.search(text, project: scope, limit: 50, recordActivity: recordActivity)
                }.value
                guard !Task.isCancelled else { return }
                hits = found
                if recordActivity { refreshActivities() }
            } catch {
                guard !Task.isCancelled else { return }
                store.recordError(error, operation: "检索失败")
                refreshActivities()
                self.error = error.localizedDescription
            }
        }
    }

    func capture(_ value: Bool, since: Date? = nil) {
        act { try $0.configureCapture(enabled: value, resetTo: since?.timeIntervalSince1970) }
        reconfigureScheduling(runInitialScan: false)
        if value { Task { await scan(force: since != nil) } }
    }

    func captureAntigravity(_ value: Bool, since: Date? = nil) {
        act {
            try $0.configureCapture(enabled: value, resetTo: since?.timeIntervalSince1970,
                                    enabledKey: AntigravitySource.enabledKey,
                                    cursorKey: AntigravitySource.cursorKey)
        }
        reconfigureScheduling(runInitialScan: false)
        if value { Task { await scanAntigravity() } }
    }

    func loginSetting(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            login = SMAppService.mainApp.status == .enabled
            if value && !login { status = "请在系统设置的登录项中批准 Agent Memory。" }
        } catch { self.error = error.localizedDescription }
    }

    func copyInstruction(_ text: String, message: String = "已复制指令，粘贴到 Agent 中继续") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        playCopySound()
        showCopyToast(message)
    }

    private func playCopySound() {
        let sound = NSSound(named: NSSound.Name("Pop")) ?? NSSound(named: NSSound.Name("Tink"))
        sound?.stop()
        sound?.play()
    }

    private func showCopyToast(_ message: String) {
        copyToastTask?.cancel()
        withAnimation(.easeOut(duration: 0.18)) {
            copyToast = CopyToast(message: message)
        }
        copyToastTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2.6)) }
            catch { return }
            withAnimation(.easeIn(duration: 0.22)) {
                self?.copyToast = nil
            }
        }
    }

    func dismissCopyToast() {
        copyToastTask?.cancel()
        withAnimation(.easeIn(duration: 0.15)) {
            copyToast = nil
        }
    }

    enum SetupAction { case verify, connect, enableRecall, disableRecall }

    private func verifyMissingAgentConnections() {
        if connection == nil { configureCodex(.verify, silently: true) }
        if antigravityConnection == nil { configureAntigravity(.verify, silently: true) }
    }

    func configureAntigravity(_ action: SetupAction = .verify) {
        configureAntigravity(action, silently: false)
    }

    private func configureAntigravity(_ action: SetupAction, silently: Bool) {
        guard !checkingAntigravity, store != nil else { return }
        guard let bridge = Bundle.main.url(forAuxiliaryExecutable: "agent-memory-mcp") else {
            if !silently { antigravitySetupError = "应用包里找不到 Agent Memory 连接工具。" }
            return
        }
        let socket = applicationSocket
        checkingAntigravity = true
        if !silently { antigravitySetupError = nil }
        Task {
            defer {
                checkingAntigravity = false
                if !silently { refresh() }
            }
            do {
                if action != .verify {
                    try await Task.detached(priority: .userInitiated) {
                        switch action {
                        case .verify: break
                        case .connect: try AntigravitySetup.connect(bridge: bridge)
                        case .enableRecall:
                            try AntigravitySetup.installHook(bridge: bridge)
                            try AntigravitySetup.setRecall(true, socket: socket)
                        case .disableRecall:
                            try AntigravitySetup.setRecall(false, socket: socket)
                            try AntigravitySetup.removeHook(bridge: bridge)
                        }
                    }.value
                }
                antigravityConnection = try await Task.detached(priority: silently ? .utility : .userInitiated) {
                    try AntigravitySetup.verify(bridge: bridge, socket: socket)
                }.value
            } catch {
                if !silently { antigravitySetupError = error.localizedDescription }
                if action == .verify || action == .connect { antigravityConnection = nil }
            }
        }
    }

    func copyAntigravitySetupInstructions() {
        guard let bridge = Bundle.main.url(forAuxiliaryExecutable: "agent-memory-mcp") else { return }
        let command = CodexSetup.shellQuote(bridge.path) + " --setup-antigravity"
        let prompt = """
            \(AntigravitySetup.setupPromptTitle)

            请在当前 Mac 为我连接 Agent Memory MCP，并准备用户级自动检索 Hook。执行下面这条由应用生成的命令：
            \(command)

            命令结束后汇报 MCP 与 Hook 验证结果，提示我在 Antigravity 刷新 MCP Servers 并新开对话，发送「\(AntigravitySetup.testPrompt)」完成自动检索验证。
            """
        copyInstruction(prompt)
    }

    func copyAntigravityRecallTestPrompt() {
        copyInstruction(AntigravitySetup.testPrompt)
    }

    func configureCodex(_ action: SetupAction = .verify) {
        configureCodex(action, silently: false)
    }

    private func configureCodex(_ action: SetupAction, silently: Bool) {
        guard !checkingConnection, store != nil else { return }
        guard let bridge = Bundle.main.url(forAuxiliaryExecutable: "agent-memory-mcp") else {
            if !silently { setupError = "应用包里找不到 Agent Memory 连接工具。" }
            return
        }
        let socket = applicationSocket
        checkingConnection = true
        if !silently { setupError = nil }
        Task {
            defer {
                checkingConnection = false
                if !silently { refresh() }
            }
            do {
                if action != .verify {
                    try await Task.detached(priority: .userInitiated) {
                        switch action {
                        case .verify: break
                        case .connect: try CodexSetup.connect(bridge: bridge)
                        case .enableRecall:
                            try CodexSetup.installHook(bridge: bridge)
                            try CodexSetup.setRecall(true, socket: socket)
                        case .disableRecall:
                            try CodexSetup.setRecall(false, socket: socket)
                            try CodexSetup.removeHook(bridge: bridge)
                        }
                    }.value
                }
                connection = try await Task.detached(priority: silently ? .utility : .userInitiated) {
                    try CodexSetup.verify(bridge: bridge, socket: socket)
                }.value
            } catch {
                if !silently { setupError = error.localizedDescription }
                if action == .verify || action == .connect { connection = nil }
            }
        }
    }

    func copyAgentSetupInstructions() {
        guard let bridge = Bundle.main.url(forAuxiliaryExecutable: "agent-memory-mcp") else { return }
        let command = CodexSetup.shellQuote(bridge.path) + " --setup-codex"
        let prompt = """
            \(CodexSetup.setupPromptTitle)

            请在当前 Mac 为我连接 Agent Memory MCP，并准备用户级自动检索 Hook。执行下面这条由应用生成的命令：
            \(command)

            如 Codex 需要批准运行，按正常流程请求批准。命令结束后汇报 MCP 验证结果，请我在 Codex 的「设置 → 勾子（Hooks）」审核 Agent Memory 的 UserPromptSubmit，然后回到 Agent Memory 运行验证。不要替我修改 Hook 信任或工作区信任。
            """
        copyInstruction(prompt)
    }

    func openRecallTest() {
        guard let url = CodexSetup.testURL, NSWorkspace.shared.open(url) else {
            setupError = "无法打开 Codex 桌面应用。也可以新开本地聊天并发送「\(CodexSetup.testPrompt)」。"
            return
        }
    }

    func openHookReview() {
        guard let launcher = Bundle.main.url(forResource: "review-codex-hooks", withExtension: "command"),
              let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            setupError = "无法打开终端审核入口。请在 Codex CLI 中输入 /hooks。"
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([launcher], withApplicationAt: terminal, configuration: configuration) { [weak self] _, error in
            if let error {
                Task { @MainActor in self?.setupError = "无法打开终端：\(error.localizedDescription)" }
            }
        }
    }

    func copyDreamInstructions() {
        copyInstruction("使用 agent-memory MCP 工具帮我做梦，并写回这一批结果。")
    }

    func copyBatchDream() {
        refresh()
        guard let through = dashboard?.queuedThrough else { return }
        copyInstruction(CodexSource.batchDreamPrompt(through: through))
    }

    func scan(force: Bool = false) async {
        guard let store, enabled, !scanning else { return }
        scanning = true
        updateRuntimeHealth()
        var didChange = false
        defer {
            scanning = false
            updateRuntimeHealth()
            if didChange { refresh() }
            else { refreshActivities() }
        }
        do {
            let result = try await Task.detached(priority: .utility) {
                try CodexSource.scan(store: store, force: force)
            }.value
            codexScanFailed = false
            let hasActivity = result.scannedThreads > 0 || result.inserted > 0 || result.skippedThreads > 0
            if force || hasActivity || lastScan == nil {
                lastScan = Date()
                if hasActivity || force {
                    status = "检查了 \(result.scannedThreads) 条聊天，新增 \(result.inserted) 条记录"
                    if result.skippedThreads > 0 { status += "，\(result.skippedThreads) 条聊天暂无法读取" }
                } else {
                    status = smartCapture ? "智能监听中，暂无新聊天变化" : "暂无新聊天变化"
                }
                if result.inserted > 0 { didChange = true }
            }
        } catch {
            codexScanFailed = true
            self.error = error.localizedDescription
        }
    }

    func scanAntigravity(force: Bool = false) async {
        guard let store, antigravityEnabled, !antigravityScanning else { return }
        antigravityScanning = true
        updateRuntimeHealth()
        var didChange = false
        defer {
            antigravityScanning = false
            updateRuntimeHealth()
            if didChange { refresh() }
            else { refreshActivities() }
        }
        do {
            let result = try await Task.detached(priority: .utility) {
                try AntigravitySource.scan(store: store)
            }.value
            antigravityScanFailed = false
            let hasActivity = result.scannedThreads > 0 || result.inserted > 0 || result.skippedThreads > 0
            if force || hasActivity || antigravityLastScan == nil {
                antigravityLastScan = Date()
                if hasActivity || force {
                    antigravityStatus = "检查了 \(result.scannedThreads) 条聊天，新增 \(result.inserted) 条记录"
                    if result.skippedThreads > 0 { antigravityStatus += "，\(result.skippedThreads) 条聊天缺少项目归属或暂无法读取" }
                } else {
                    antigravityStatus = smartCapture ? "智能监听中，暂无新聊天变化" : "暂无新聊天变化"
                }
                if result.inserted > 0 { didChange = true }
            }
        } catch {
            antigravityScanFailed = true
            self.error = error.localizedDescription
        }
    }

    private func refreshIndex() async {
        guard let store, embeddingState != .indexing else { return }
        embeddingState = .indexing
        updateRuntimeHealth()
        defer { updateRuntimeHealth() }
        do {
            let ready = try await Task.detached(priority: .utility) { try store.repairVectors() }.value
            embeddingReady = ready
            embeddingState = ready ? .ready : .unavailable
            refreshHealthSummary()
        } catch {
            embeddingReady = false
            embeddingState = .failed
            store.recordError(error, operation: "向量索引更新失败")
            refreshActivities()
            self.error = error.localizedDescription
        }
    }

    func show(_ hit: SearchHit) {
        selectedMemory = hit
        guard let store else { return }
        do {
            evidence = try store.evidence(hit.memory.evidenceIDs)
            history = try store.history(hit.id)
        } catch { self.error = error.localizedDescription }
    }

    func show(_ decision: Decision) {
        guard store != nil else { return }
        do {
            evidence = try self.evidence(ids: decision.proposal.evidenceIDs)
            if let id = decision.proposal.memoryID, let version = decision.proposal.expectedVersion {
                previous = try memory(id: id, version: version)
            } else {
                previous = nil
            }
        } catch { self.error = error.localizedDescription }
    }

    func exclude(_ evidence: Evidence, byProject: Bool) {
        act { try $0.exclude(evidence, project: byProject) }
    }

    func removeExclusion(_ value: String, byProject: Bool) {
        let values = byProject ? excludedProjects : excludedThreads
        act { try $0.setSetting(byProject ? "excludedProjects" : "excludedThreads",
                               values.filter { $0 != value }.joined(separator: "\n")) }
    }

    func review(_ decision: Decision, accept: Bool) {
        act { try $0.review(decision.id, accept: accept) }
        if accept { Task { await refreshIndex() } }
    }
    func undo(_ batchID: String) {
        act(operation: "做梦撤销失败") { try $0.undo(batchID) }
        Task { await refreshIndex() }
    }
    func setRecallCrossProject(_ value: Bool) { act { try $0.configureRecallCrossProject(value) } }
    func setSmartCapture(_ value: Bool) {
        act { try $0.configureSmartCapture(value) }
        reconfigureScheduling(runInitialScan: !value)
    }
    func setCloseBehavior(_ value: CloseBehavior) {
        closeBehavior = value
        act { try $0.setSetting("closeBehavior", value.rawValue) }
    }

    private func act(operation: String = "更新记忆库失败", _ action: (MemoryStore) throws -> Void) {
        guard let store else { return }
        do {
            try action(store)
            refresh()
        } catch {
            store.recordError(error, operation: operation)
            refreshActivities()
            self.error = error.localizedDescription
        }
    }
}
