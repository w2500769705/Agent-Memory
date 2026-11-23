import AgentMemoryCore
import SwiftUI

private enum MemoryScopeMode: String, CaseIterable, Identifiable {
    case all = "全部"
    case global = "仅全局"
    case project = "仅当前项目"
    case projectAndGlobal = "项目+全局"

    var id: Self { self }

    var needsProjectPath: Bool {
        self == .project || self == .projectAndGlobal
    }
}

private struct MemoryReviewRequest: Equatable {
    let ids: Set<String>
    let graphNodes: [MemoryGraphNode]
}

@MainActor
private final class MemorySearchState: ObservableObject {
    @Published var scopeMode: MemoryScopeMode = .all
    @Published var inspection: SearchInspection?
    @Published var isSearching = false
    @Published var searchError: String?
    @Published var showFilteredCandidates = false
    @Published var reviewHits: [SearchHit] = []
    var inspectTask: Task<Void, Never>?
}

struct MemoryListView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var model: AppModel
    var searchFocused: FocusState<Bool>.Binding
    @Binding var reviewMode: MemoryReviewMode
    @Binding var displayMode: MemoryDisplayMode
    let onSelectMemory: (SearchHit) -> Void
    let onInspectMemoryID: (String) -> Void

    @StateObject private var searchState = MemorySearchState()

    private var dormantIDSet: Set<String> {
        Set(model.healthSummary.dormantMemoryIDs)
    }

    private var displayedHits: [SearchHit] {
        searchState.inspection?.hits ?? model.hits
    }

    private var filteredCandidates: [SearchHit] {
        searchState.inspection?.filteredCandidates ?? []
    }

    private var knownProjects: [String] {
        var paths = Set<String>()
        for hit in model.hits {
            if let path = hit.memory.project, !path.isEmpty { paths.insert(path) }
        }
        if let inspection = searchState.inspection {
            for hit in inspection.hits {
                if let path = hit.memory.project, !path.isEmpty { paths.insert(path) }
            }
            for hit in inspection.filteredCandidates {
                if let path = hit.memory.project, !path.isEmpty { paths.insert(path) }
            }
        }
        return paths.sorted()
    }

    private var resolvedScope: SearchScope {
        switch searchState.scopeMode {
        case .all:
            return .all
        case .global:
            return .global
        case .project:
            return .project(model.project.trimmingCharacters(in: .whitespacesAndNewlines))
        case .projectAndGlobal:
            return .projectAndGlobal(model.project.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private var needsValidProjectHint: Bool {
        searchState.scopeMode.needsProjectPath && !model.project.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayMode == .archived ? "已归档记忆" : "记忆与检索透视")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(theme.textPrimary)
                    if displayMode == .list && reviewMode == .standard {
                        Text("支持四档作用域检索、Vector / BM25 / RRF 分项透视与边缘过滤排查")
                            .font(.caption)
                            .foregroundStyle(theme.textSecondary)
                    }
                }
                Spacer()
                SegmentedPillBar(
                    options: MemoryDisplayMode.allCases,
                    selection: $displayMode,
                    label: { $0.label(archivedCount: model.healthSummary.archivedCount) },
                    icon: { $0.icon },
                    compact: true
                )
            }

            switch displayMode {
            case .archived:
                ArchivedMemoryList(model: model, searchFocused: searchFocused, onSelectMemory: onSelectMemory)
            case .galaxy:
                MemoryGalaxyView(model: model, mode: .interactiveFull, onSelectMemoryID: onInspectMemoryID)
            case .list:
                if reviewMode == .standard {
                    listContent
                } else {
                    reviewContent
                }
            }
        }
        .padding(20)
        .background(Color.clear)
        .onAppear {
            if model.projectFilter && !model.project.isEmpty {
                searchState.scopeMode = .projectAndGlobal
            }
            if displayMode == .list && reviewMode == .standard {
                let canShowCachedImmediately = model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && searchState.scopeMode == .all
                    && !model.hits.isEmpty
                runInspectSearch(debounce: false, initialDelayMs: canShowCachedImmediately ? 80 : 0)
            }
        }
        .onDisappear {
            searchState.inspectTask?.cancel()
        }
        .onChange(of: displayMode) { _, _ in updateSearch() }
        .onChange(of: reviewMode) { _, _ in
            searchState.reviewHits = []
            updateSearch()
        }
        .onChange(of: searchState.scopeMode) { _, newValue in
            if newValue.needsProjectPath && model.project.isEmpty, let first = knownProjects.first {
                model.project = first
            }
            model.projectFilter = newValue.needsProjectPath && model.project.hasPrefix("/")
            updateSearch()
        }
        .onChange(of: model.dashboard?.memories) { _, _ in
            updateSearch()
        }
    }

    @ViewBuilder
    private var listContent: some View {
        filterHeader

        if let error = searchState.searchError {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(theme.warning)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Button("重试") { runInspectSearch(debounce: false) }
                    .buttonStyle(SoftActionButtonStyle(tint: theme.warning, compact: true))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(theme.warningSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }

        if displayedHits.isEmpty && filteredCandidates.isEmpty {
            Spacer(minLength: 12)
            EmptyStateCard(
                icon: "magnifyingglass",
                title: emptyStateTitle,
                description: emptyStateDescription,
                actionTitle: hasActiveFilter ? "清除筛选" : nil
            ) {
                model.query = ""
                searchState.scopeMode = .all
                model.projectFilter = false
                runInspectSearch(debounce: false)
            }
            Spacer()
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if displayedHits.isEmpty && !filteredCandidates.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                                .foregroundStyle(theme.warning)
                            Text("没有直接命中的记忆，但下方有 \(filteredCandidates.count) 条边缘过滤候选可供透视排查。")
                                .font(.callout)
                                .foregroundStyle(theme.textSecondary)
                            Spacer()
                        }
                        .surfaceCard(cornerRadius: 10, padding: 12)
                    } else {
                        ForEach(displayedHits) { hit in
                            MemoryCardRow(
                                hit: hit,
                                isSelected: model.selectedMemory?.id == hit.id,
                                isDormant: dormantIDSet.contains(hit.id),
                                isFilteredCandidate: false
                            ) {
                                onSelectMemory(hit)
                            }
                        }
                    }

                    if !filteredCandidates.isEmpty {
                        filteredCandidatesPanel
                            .padding(.top, 6)
                    }
                }
                .padding(.bottom, 12)
            }
        }
    }

    private var hasActiveFilter: Bool {
        !model.query.isEmpty || searchState.scopeMode != .all
    }

    private var emptyStateTitle: String {
        if needsValidProjectHint {
            return "请先选择或输入项目路径"
        }
        return model.query.isEmpty ? "暂无匹配的记忆" : "没有找到「\(model.query)」相关记忆"
    }

    private var emptyStateDescription: String {
        if needsValidProjectHint {
            return "请在上方输入绝对路径或点击下方已知项目胶囊，以按项目作用域透视检索结果。"
        }
        return model.query.isEmpty
            ? "当 Agent 完成做梦并写入后，长期记忆会以卡片形式展示在这里。"
            : "尝试更换关键词，或切换回「全部」作用域查看。"
    }

    private func runInspectSearch(debounce: Bool, initialDelayMs: UInt64 = 0) {
        searchState.inspectTask?.cancel()
        let query = model.query
        let scope = resolvedScope
        let debounceMs: UInt64 = (debounce && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ? 180 : 0
        let waitMs = max(debounceMs, initialDelayMs)

        searchState.inspectTask = Task {
            if waitMs > 0 {
                do { try await Task.sleep(for: .milliseconds(waitMs)) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            searchState.isSearching = true
            searchState.searchError = nil
            defer {
                if !Task.isCancelled {
                    searchState.isSearching = false
                }
            }
            do {
                let result = try await model.inspectSearch(
                    query,
                    scope: scope,
                    limit: 50,
                    includeFilteredCandidates: true
                )
                guard !Task.isCancelled else { return }
                searchState.inspection = result
            } catch {
                guard !Task.isCancelled else { return }
                searchState.searchError = error.localizedDescription
            }
        }
    }

    private func updateSearch() {
        if displayMode == .list && reviewMode == .standard {
            runInspectSearch(debounce: false)
        } else {
            searchState.inspectTask?.cancel()
            searchState.isSearching = false
        }
    }

    private var reviewIDs: Set<String> {
        let dormant = dormantIDSet
        guard reviewMode == .leastUsed else { return dormant }
        return dormant.union(model.memoryGraph.nodes.map(\.id)).union(model.hits.map(\.id))
    }

    private var reviewContent: some View {
        let dormant = reviewMode == .dormant
        let ids = reviewIDs
        let request = MemoryReviewRequest(ids: ids, graphNodes: dormant ? [] : model.memoryGraph.nodes)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Label(dormant ? "沉睡记忆" : "低频 / 最久未用", systemImage: dormant ? "moon.zzz" : "clock.arrow.circlepath")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(theme.warning)
                    Text(dormant
                         ? "超过 30 天未更新且零命中。"
                         : "先按命中次数从少到多，再按最后使用时间从早到晚。")
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer(minLength: 4)
                Button("退出整理") { reviewMode = .standard }
                    .buttonStyle(SoftActionButtonStyle(compact: true))
            }
            .surfaceCard(cornerRadius: 10, padding: 10)

            if !dormant && !ids.isEmpty && ids.count < model.healthSummary.activeCount {
                Text("本次整理范围 \(ids.count) / \(model.healthSummary.activeCount) 条活跃记忆")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(theme.textSecondary)
            }

            if ids.isEmpty {
                EmptyStateCard(
                    icon: dormant ? "moon.zzz" : "clock",
                    title: dormant ? "当前没有沉睡记忆" : "暂无可整理的记忆",
                    description: dormant ? "当前健康度诊断没有发现沉睡记忆。" : "活跃记忆加载后会显示在这里。"
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(searchState.reviewHits.filter { ids.contains($0.id) }) { hit in
                            MemoryCardRow(
                                hit: hit,
                                isSelected: model.selectedMemory?.id == hit.id,
                                isDormant: dormantIDSet.contains(hit.id),
                                isFilteredCandidate: false,
                                showsLastHit: !dormant
                            ) {
                                onSelectMemory(hit)
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
        .task(id: request) {
            var hits: [SearchHit] = []
            for (index, id) in ids.enumerated() {
                if index.isMultiple(of: 25) { await Task.yield() }
                guard !Task.isCancelled else { return }
                if let memory = try? model.memory(id: id), !memory.archived {
                    hits.append(SearchHit(memory: memory, vector: nil, keywordRank: nil, score: 0))
                }
            }
            searchState.reviewHits = hits.sorted {
                if dormant {
                    return ($0.memory.updated, $0.id) < ($1.memory.updated, $1.id)
                }
                return ($0.memory.hitCount, $0.memory.lastHitAt ?? 0, $0.memory.updated, $0.id)
                    < ($1.memory.hitCount, $1.memory.lastHitAt ?? 0, $1.memory.updated, $1.id)
            }
        }
        .id(reviewMode)
    }

    // MARK: - Filter & Telemetry Header

    private var filterHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(theme.textTertiary)
                    TextField("搜索记忆标题、正文、技术词或版本号…", text: $model.query)
                        .textFieldStyle(.plain)
                        .focused(searchFocused)
                        .onChange(of: model.query) { _, _ in
                            runInspectSearch(debounce: true)
                        }
                        .onSubmit {
                            runInspectSearch(debounce: false)
                        }
                    if searchState.isSearching {
                        ProgressView()
                            .controlSize(.mini)
                    } else if !model.query.isEmpty {
                        Button {
                            model.query = ""
                            runInspectSearch(debounce: false)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(theme.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清空搜索")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(theme.surfacePrimary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(searchFocused.wrappedValue ? theme.accentBorder : theme.hairlineBorder, lineWidth: 1)
                )

                SegmentedPillBar(
                    options: MemoryScopeMode.allCases,
                    selection: $searchState.scopeMode,
                    label: { $0.rawValue },
                    compact: true
                )
            }

            if searchState.scopeMode.needsProjectPath {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .font(.caption)
                            .foregroundStyle(theme.accent)
                        TextField("输入项目绝对路径（例如 /Users/.../repo）", text: $model.project)
                            .textFieldStyle(.plain)
                            .font(.system(.callout, design: .monospaced))
                            .onChange(of: model.project) { _, value in
                                model.projectFilter = value.hasPrefix("/")
                                runInspectSearch(debounce: true)
                            }
                            .onSubmit {
                                runInspectSearch(debounce: false)
                            }
                        if !model.project.isEmpty {
                            Button("重置") {
                                model.project = ""
                                model.projectFilter = false
                                runInspectSearch(debounce: false)
                            }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(theme.textSecondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(theme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(theme.hairlineBorder, lineWidth: 1)
                    )

                    if !knownProjects.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(knownProjects, id: \.self) { path in
                                    let active = model.project == path
                                    Button {
                                        model.project = active ? "" : path
                                        model.projectFilter = !active
                                        runInspectSearch(debounce: false)
                                    } label: {
                                        Text(URL(fileURLWithPath: path).lastPathComponent)
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(active ? theme.accent : theme.textSecondary)
                                            .padding(.horizontal, 9)
                                            .padding(.vertical, 4)
                                            .background(active ? theme.accentSoft : theme.surfacePrimary, in: Capsule())
                                            .overlay(
                                                Capsule().stroke(active ? theme.accentBorder : theme.hairlineBorder, lineWidth: 1)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    .help(path)
                                }
                            }
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                Text("共 \(displayedHits.count) 条记忆")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(theme.textTertiary)

                if let inspection = searchState.inspection {
                    ScorePill(
                        label: "耗时",
                        value: "\(inspection.elapsedMs) ms",
                        tint: theme.accent
                    )
                    if !filteredCandidates.isEmpty {
                        ScorePill(
                            label: "边缘过滤",
                            value: "\(filteredCandidates.count) 条",
                            tint: theme.warning
                        )
                    }
                }

                if !model.query.isEmpty {
                    Text("· 按混合相关性排序")
                        .font(.caption)
                        .foregroundStyle(theme.textTertiary)
                }

                Spacer()

                Text("点击条目在右侧检查器查看详情与证据")
                    .font(.caption2)
                    .foregroundStyle(theme.textTertiary)
            }
        }
    }

    // MARK: - Filtered Candidates Collapsible Panel

    private var filteredCandidatesPanel: some View {
        DisclosureGroup(isExpanded: $searchState.showFilteredCandidates) {
            VStack(alignment: .leading, spacing: 8) {
                Text("以下候选在混合检索中产生了得分，但未达到自动召回相关性门控或排名阈值，因此被过滤。可用于排查召回边界。")
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .padding(.top, 6)

                ForEach(filteredCandidates) { hit in
                    MemoryCardRow(
                        hit: hit,
                        isSelected: model.selectedMemory?.id == hit.id,
                        isDormant: dormantIDSet.contains(hit.id),
                        isFilteredCandidate: true
                    ) {
                        onSelectMemory(hit)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(theme.warning)
                Text("边缘过滤候选")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(theme.textPrimary)
                Text("\(filteredCandidates.count)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(theme.warning)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(theme.warningSoft, in: Capsule())
                Spacer()
                Text(searchState.showFilteredCandidates ? "收起" : "展开排查")
                    .font(.caption2)
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .surfaceCard(cornerRadius: 12, padding: 12)
    }
}

private struct ArchivedMemoryList: View {
    @Environment(\.theme) private var theme
    @ObservedObject var model: AppModel
    var searchFocused: FocusState<Bool>.Binding
    let onSelectMemory: (SearchHit) -> Void

    @StateObject private var query = LocalState("")
    @StateObject private var confirmingClear = LocalState(false)

    private var archiveCount: Int { model.healthSummary.archivedCount }
    private var searchQuery: String { query.value.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(theme.textTertiary)
                    TextField("搜索已归档记忆的标题或正文…", text: $query.value)
                        .textFieldStyle(.plain)
                        .focused(searchFocused)
                    if !query.value.isEmpty {
                        Button {
                            query.value = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(theme.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清空搜索")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(theme.surfacePrimary, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(
                    searchFocused.wrappedValue ? theme.accentBorder : theme.hairlineBorder
                ))

                if archiveCount > 0 {
                    Button {
                        confirmingClear.value = true
                    } label: {
                        Label("清空已归档", systemImage: "trash")
                    }
                    .buttonStyle(SoftActionButtonStyle(tint: theme.danger, compact: true))
                    .help("永久删除全部已归档记忆，包括搜索结果之外的条目")
                }
            }

            if model.archivedMemories.isEmpty {
                EmptyStateCard(
                    icon: "archivebox",
                    title: searchQuery.isEmpty ? "暂无已归档记忆" : "没有匹配的已归档记忆",
                    description: searchQuery.isEmpty ? "归档后可在这里恢复或永久删除记忆。" : "试试其他标题或正文关键词。"
                )
                .frame(maxHeight: .infinity)
            } else {
                if model.archivedMemories.count < archiveCount {
                    Text("当前展示 \(model.archivedMemories.count) 条 · 共归档 \(archiveCount) 条")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(theme.textSecondary)
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.archivedMemories) { memory in
                            archivedRow(memory)
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
        .onChange(of: searchQuery, initial: true) { _, value in
            model.refreshArchivedMemories(query: value)
        }
        .alert("永久清空所有已归档记忆？", isPresented: $confirmingClear.value) {
            Button("取消", role: .cancel) {}
            Button("永久清空", role: .destructive) { model.deleteAllArchivedMemories() }
        } message: {
            Text("将永久删除全部 \(archiveCount) 条已归档记忆及其版本历史，包括搜索结果之外的条目。此操作不可撤销。")
        }
    }

    private func archivedRow(_ memory: Memory) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Button {
                onSelectMemory(SearchHit(memory: memory, vector: nil, keywordRank: nil, score: 0))
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(memory.title)
                        .font(.headline)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(2)
                    Text(memory.body)
                        .font(.callout)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("在右侧检查器查看记忆详情")

            FlowLayout(spacing: 8, lineSpacing: 6) {
                ScopeTag(projectPath: memory.project)
                Text("归档于 \(Date(timeIntervalSince1970: memory.updated).formatted(.dateTime.year().month().day().hour().minute()))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(theme.textSecondary)
                Button {
                    model.archiveMemory(id: memory.id, archived: false)
                } label: {
                    Label("恢复", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(SoftActionButtonStyle(tint: theme.success, compact: true))
                DeleteArchivedMemoryButton(title: memory.title) { model.deleteArchivedMemory(id: memory.id) }
            }
        }
        .surfaceCard(cornerRadius: 12, padding: 14, highlighted: model.selectedMemory?.id == memory.id)
    }
}

struct DeleteArchivedMemoryButton: View {
    @Environment(\.theme) private var theme
    let title: String
    let delete: () -> Void

    @StateObject private var confirming = LocalState(false)

    var body: some View {
        Button {
            confirming.value = true
        } label: {
            Label("永久删除", systemImage: "trash")
        }
        .buttonStyle(SoftActionButtonStyle(tint: theme.danger, compact: true))
        .alert("永久删除这条记忆？", isPresented: $confirming.value) {
            Button("取消", role: .cancel) {}
            Button("永久删除", role: .destructive, action: delete)
        } message: {
            Text("将永久删除「\(title)」及其版本历史。此操作不可撤销。")
        }
    }
}

private struct MemoryCardRow: View {
    @Environment(\.theme) private var theme
    let hit: SearchHit
    let isSelected: Bool
    let isDormant: Bool
    let isFilteredCandidate: Bool
    var showsLastHit: Bool = false
    let action: () -> Void

    @StateObject private var hovered = LocalState(false)

    var body: some View {
        let isHovered = hovered.value
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Text(hit.memory.title)
                        .font(.headline)
                        .foregroundStyle(isFilteredCandidate ? theme.textSecondary : theme.textPrimary)
                        .lineLimit(1)
                    if isFilteredCandidate {
                        ScorePill(label: "门控", value: "已过滤", tint: theme.warning)
                    }
                    Spacer()
                    Text("v\(hit.memory.version)")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(theme.textTertiary)
                    Text(activityDate)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(theme.textTertiary)
                }

                Text(hit.memory.body)
                    .font(.callout)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(2)
                    .lineSpacing(2)

                HStack(spacing: 6) {
                    ScopeTag(projectPath: hit.memory.project)
                    ScorePill(
                        label: "热度",
                        value: "\(hit.memory.hitCount) 次",
                        tint: hit.memory.hitCount > 0 ? theme.warning : theme.textTertiary
                    )
                    if !hit.memory.evidenceIDs.isEmpty {
                        ScorePill(label: "证据", value: "\(hit.memory.evidenceIDs.count)")
                    }
                    if isDormant {
                        ScorePill(label: "活性", value: "沉睡", tint: theme.warning)
                    }
                    Spacer()
                    if let vector = hit.vector {
                        ScorePill(label: "Vec", value: String(format: "%.2f", vector), tint: theme.accent)
                    }
                    if let rank = hit.keywordRank {
                        ScorePill(label: "BM25", value: "#\(rank)", tint: theme.info)
                    }
                    if hit.score > 0 {
                        ScorePill(label: "RRF", value: String(format: "%.3f", hit.score), tint: theme.success)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                isSelected ? theme.accentSoft : (isHovered ? theme.surfaceElevated : (isFilteredCandidate ? theme.surfaceSecondary : theme.surfacePrimary)),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? theme.accentBorder : (isHovered ? theme.strongBorder : theme.hairlineBorder), lineWidth: 1)
            )
            .shadow(color: theme.cardShadow, radius: isSelected ? 6 : 3, y: 1)
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
    }

    private var activityDate: String {
        if showsLastHit {
            guard let lastHit = hit.memory.lastHitAt else { return "从未命中" }
            let date = Date(timeIntervalSince1970: lastHit)
            return "命中于 \(date.formatted(.dateTime.year().month().day()))"
        }
        return Date(timeIntervalSince1970: hit.memory.updated).formatted(.dateTime.month().day().hour().minute())
    }
}
