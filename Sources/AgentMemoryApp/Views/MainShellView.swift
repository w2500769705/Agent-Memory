import AgentMemoryCore
import SwiftUI

@MainActor
private final class ShellState: ObservableObject {
    @Published var selection: AppPage = .overview
    @Published var setupAgent: AgentBrand = .codex
    @Published var memoryDisplayMode: MemoryDisplayMode = .list
    @Published var filterDormantOnly = false
    @Published var pickedDecision: Decision?
    @Published var pendingUndo: String?
    @Published var showBackfill = false
    @Published var backfillDate = Calendar.current.startOfDay(for: Date())
    @Published var inspectorPresented = false
    @Published var pendingInspectMemoryID: String?
    @Published var sidebarExpanded = false
    @Published var dreamResonanceTrigger: Date? = nil

    private var sidebarCollapseTask: Task<Void, Never>?

    func setSidebarHovered(_ hovering: Bool) {
        sidebarCollapseTask?.cancel()
        if hovering {
            if !sidebarExpanded {
                withAnimation(.spring(response: 0.36, dampingFraction: 0.78)) {
                    sidebarExpanded = true
                }
            }
        } else {
            sidebarCollapseTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
                guard !Task.isCancelled else { return }
                withAnimation(.spring(response: 0.36, dampingFraction: 0.78)) {
                    self?.sidebarExpanded = false
                }
            }
        }
    }
}

struct MainShellView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var model: AppModel
    @StateObject private var state = ShellState()
    @FocusState private var searchFocused: Bool

    private var isFullScreenGalaxy: Bool {
        state.selection == .memory && state.memoryDisplayMode == .galaxy
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // Layer 0: Borderless Full-Window 3D Elastic Memory Galaxy
            MemoryGalaxyView(
                model: model,
                mode: isFullScreenGalaxy ? .interactiveFull : .ambientBackdrop,
                dreamResonanceTrigger: state.dreamResonanceTrigger,
                onSelectMemoryID: { memoryID in
                    inspectMemory(id: memoryID)
                }
            )
            .ignoresSafeArea()

            // Layer 1: Top 62pt Native Window Drag & Double-Click Zoom Region
            WindowDragRegion()
                .frame(maxWidth: .infinity)
                .frame(height: 62)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea(edges: .top)

            // Layer 2: Spatial Content Area (cleared past the 54pt collapsed rail)
            VStack(spacing: 0) {
                if let error = model.error {
                    ErrorBanner(message: error) {
                        model.error = nil
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                }

                contentLayer
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.leading, 68)

            // Layer 3: Leftmost Floating Hover-Expand Liquid Glass Navigation Rail
            floatingLiquidGlassRail
                .padding(.leading, 12)
                .padding(.top, 10)
                .padding(.bottom, 16)
                .zIndex(20)
        }
        .frame(minWidth: 860, minHeight: 540)
        .navigationTitle(state.selection.rawValue)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .inspector(isPresented: $state.inspectorPresented) {
            InspectorView(
                model: model,
                selection: state.selection,
                pickedDecision: $state.pickedDecision
            )
            .inspectorColumnWidth(min: 280, ideal: 340, max: 460)
        }
        .toolbar {
            toolbarContent
        }
        .background {
            Button("") { focusMemorySearch() }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
        .overlay(alignment: .bottom) {
            if let toast = model.copyToast {
                CopyToastBanner(message: toast.message) {
                    model.dismissCopyToast()
                }
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onChange(of: state.selection) { _, selection in
            if selection != .dream {
                state.pickedDecision = nil
            }
            if selection != .memory {
                state.filterDormantOnly = false
            }
            // Auto-collapse right inspector on tab switch unless triggered by a pending inspect-memory jump.
            if state.pendingInspectMemoryID == nil {
                state.inspectorPresented = false
            }
            if selection == .memory {
                if state.memoryDisplayMode == .galaxy {
                    model.refreshMemoryGraph()
                } else {
                    model.find()
                }
            }
        }
        .onChange(of: state.showBackfill) { _, isShown in
            if isShown {
                state.inspectorPresented = false
            }
        }
        .onChange(of: state.pendingUndo) { _, batchID in
            if batchID != nil {
                state.inspectorPresented = false
            }
        }
        .onChange(of: model.hits.map(\.id)) { _, _ in
            guard let targetID = state.pendingInspectMemoryID,
                  let hit = model.hits.first(where: { $0.id == targetID }) else { return }
            state.pendingInspectMemoryID = nil
            model.show(hit)
            state.inspectorPresented = true
        }
        .alert(
            "撤销做梦批次？",
            isPresented: Binding(get: { state.pendingUndo != nil }, set: { if !$0 { state.pendingUndo = nil } })
        ) {
            Button("取消", role: .cancel) { state.pendingUndo = nil }
            Button("撤销批次", role: .destructive) {
                if let pendingUndo = state.pendingUndo {
                    model.undo(pendingUndo)
                }
                state.pendingUndo = nil
            }
        } message: {
            Text("恢复这个批次修改前的记忆。期间已改动的记忆会阻止本次撤销。")
        }
        .sheet(isPresented: $state.showBackfill) {
            VStack(alignment: .leading, spacing: 16) {
                Text("回填 Codex 聊天")
                    .font(.headline)
                Text("从选定日期开始扫描并补录历史 Codex 对话。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DatePicker("开始日期", selection: $state.backfillDate, in: ...Date(), displayedComponents: .date)
                HStack {
                    Spacer()
                    Button("取消") { state.showBackfill = false }
                        .buttonStyle(SoftActionButtonStyle())
                    Button("开始回填") {
                        model.capture(true, since: state.backfillDate)
                        state.showBackfill = false
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
                }
            }
            .padding(24)
            .frame(width: 340)
        }
    }

    // MARK: - Content Layer

    @ViewBuilder
    private var contentLayer: some View {
        switch state.selection {
        case .overview:
            OverviewView(
                model: model,
                selection: $state.selection,
                isSidebarExpanded: state.sidebarExpanded,
                onSearchMemory: { query in searchFromOverview(query) },
                onInspectMemoryID: { memoryID in inspectMemory(id: memoryID) },
                onOpenAgentSettings: { agent in openAgentSettings(agent) },
                onInspectDormantMemories: { inspectDormantMemories() },
                onOpenGalaxy: { openMemoryGalaxy() },
                onTriggerDreamResonance: { state.dreamResonanceTrigger = Date() },
                onNonDetailAction: { state.inspectorPresented = false }
            )

        case .memory where state.memoryDisplayMode == .galaxy:
            // Full-screen 3D galaxy lives in Layer 0; float only a compact mode switcher pill here
            VStack {
                HStack {
                    Spacer()
                    SegmentedPillBar(
                        options: MemoryDisplayMode.allCases,
                        selection: $state.memoryDisplayMode,
                        label: { $0.rawValue },
                        icon: { $0.icon },
                        compact: true
                    )
                    .liquidGlassCapsule()
                }
                .padding(.top, 4)
                .padding(.trailing, 18)
                Spacer()
            }

        default:
            // Translucent Liquid Glass Main Panel for Memory List / Dream / Activity / Settings
            glassPageContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .liquidGlassSurface(cornerRadius: 20, panel: true)
                .padding(.leading, 10)
                .padding(.trailing, 16)
                .padding(.top, 6)
                .padding(.bottom, 16)
                .rotation3DEffect(
                    .degrees(state.sidebarExpanded ? -12 : 0),
                    axis: (x: 0, y: 1, z: 0),
                    anchor: .trailing,
                    perspective: 0.45
                )
                .offset(x: state.sidebarExpanded ? 72 : 0)
                .scaleEffect(state.sidebarExpanded ? 0.93 : 1.0, anchor: .trailing)
                .opacity(state.sidebarExpanded ? 0.64 : 1.0)
                .blur(radius: state.sidebarExpanded ? 0.8 : 0)
                .animation(.spring(response: 0.36, dampingFraction: 0.78), value: state.sidebarExpanded)
        }
    }

    @ViewBuilder
    private var glassPageContent: some View {
        switch state.selection {
        case .overview:
            EmptyView()
        case .memory:
            MemoryListView(
                model: model,
                searchFocused: $searchFocused,
                filterDormantOnly: $state.filterDormantOnly,
                displayMode: $state.memoryDisplayMode,
                onSelectMemory: { hit in
                    model.show(hit)
                    state.inspectorPresented = true
                },
                onInspectMemoryID: { memoryID in
                    inspectMemory(id: memoryID)
                }
            )
        case .dream:
            DreamView(
                model: model,
                pickedDecision: $state.pickedDecision,
                pendingUndo: $state.pendingUndo
            ) { decision in
                state.pickedDecision = decision
                model.show(decision)
                state.inspectorPresented = true
            }
        case .activity:
            ActivityView(model: model) { memoryID in
                inspectMemory(id: memoryID)
            }
        case .settings:
            SettingsView(
                model: model,
                showBackfill: $state.showBackfill,
                selectedAgent: $state.setupAgent
            )
        }
    }

    // MARK: - Hover-Expand Liquid Glass Navigation Rail

    private var floatingLiquidGlassRail: some View {
        let expanded = state.sidebarExpanded
        let runtime = model.overallRuntimeStatus

        return VStack(alignment: .leading, spacing: 6) {
            ForEach(AppPage.allCases) { page in
                let isSelected = state.selection == page
                let badge = page.badgeCount(in: model)
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.80)) {
                        state.selection = page
                    }
                } label: {
                    HStack(spacing: 11) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: page.icon)
                                .font(.system(size: 15, weight: isSelected ? .semibold : .medium))
                                .foregroundStyle(isSelected ? theme.accent : theme.textSecondary)
                                .frame(width: 24, height: 24)

                            if !expanded && badge > 0 {
                                Circle()
                                    .fill(theme.warning)
                                    .frame(width: 6.5, height: 6.5)
                                    .shadow(color: theme.warning.opacity(0.75), radius: 3)
                                    .offset(x: 2, y: -1)
                            }
                        }

                        if expanded {
                            Text(page.rawValue)
                                .font(.callout.weight(isSelected ? .semibold : .medium))
                                .foregroundStyle(isSelected ? theme.textPrimary : theme.textSecondary)
                                .lineLimit(1)
                                .transition(.opacity.combined(with: .move(edge: .leading)))

                            Spacer(minLength: 4)

                            if badge > 0 {
                                Text("\(badge)")
                                    .font(.caption2.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(theme.warning)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(theme.warningSoft, in: Capsule())
                                    .transition(.opacity)
                            }
                        }
                    }
                    .padding(.horizontal, expanded ? 11 : 7)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: expanded ? .leading : .center)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(isSelected ? theme.accentSoft : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(isSelected ? theme.accent.opacity(theme.isDark ? 0.36 : 0.28) : Color.clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .help(page.rawValue)
            }

            Spacer(minLength: 8)

            Divider()
                .overlay(theme.hairlineBorder)
                .padding(.horizontal, 6)

            // Bottom runtime status dot / expanded status footer
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if runtime.spinning {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.75)
                            .frame(width: 14, height: 14)
                    } else {
                        Circle()
                            .fill(runtime.kind.color(in: theme))
                            .frame(width: 8, height: 8)
                            .shadow(color: runtime.kind.color(in: theme).opacity(0.7), radius: 4)
                            .frame(width: 14, height: 14)
                    }

                    if expanded {
                        Text(runtime.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: expanded ? .leading : .center)

                if expanded {
                    HStack(spacing: 8) {
                        railAgentIndicator(.codex, active: model.enabled)
                        railAgentIndicator(.antigravity, active: model.antigravityEnabled)
                    }
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, expanded ? 10 : 6)
            .padding(.vertical, 6)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .frame(width: expanded ? 176 : 54)
        .frame(maxHeight: .infinity)
        .liquidGlassSurface(cornerRadius: 20, highlighted: expanded)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onHover { hovering in
            state.setSidebarHovered(hovering)
        }
    }

    private func railAgentIndicator(_ brand: AgentBrand, active: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(active ? brand.color(in: theme) : theme.textTertiary.opacity(0.45))
                .frame(width: 5.5, height: 5.5)
            Text(brand.rawValue)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(active ? theme.textSecondary : theme.textTertiary)
                .lineLimit(1)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                focusMemorySearch()
            } label: {
                Label("搜索记忆", systemImage: "magnifyingglass")
            }
            .keyboardShortcut("k", modifiers: .command)
            .help("搜索记忆 (⌘K / ⌘F)")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                model.refresh()
                Task { await model.scanAllEnabled(force: true) }
            } label: {
                Label("刷新并扫描", systemImage: "arrow.clockwise")
            }
            .disabled(model.isAnyScanning || model.store == nil)
            .help("刷新状态并立即扫描启用的来源")
        }

        ToolbarItem(placement: .primaryAction) {
            Menu {
                ForEach(AppThemeMode.allCases) { mode in
                    Button {
                        model.themeMode = mode
                    } label: {
                        HStack {
                            Label(mode.label, systemImage: mode.icon)
                            if model.themeMode == mode {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Label("主题：\(model.themeMode.label)", systemImage: model.themeMode.icon)
            }
            .help("切换外观主题（当前：\(model.themeMode.label)）")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    state.inspectorPresented.toggle()
                }
            } label: {
                Label("切换检查器", systemImage: "sidebar.trailing")
            }
            .help(state.inspectorPresented ? "隐藏右侧检查器" : "显示右侧检查器")
        }
    }

    // MARK: - Navigation & Inspector Actions

    private func focusMemorySearch() {
        state.pendingInspectMemoryID = nil
        state.memoryDisplayMode = .list
        state.inspectorPresented = false
        state.selection = .memory
        DispatchQueue.main.async {
            searchFocused = true
        }
    }

    private func searchFromOverview(_ query: String) {
        state.pendingInspectMemoryID = nil
        state.memoryDisplayMode = .list
        state.filterDormantOnly = false
        model.query = query
        state.inspectorPresented = false
        state.selection = .memory
        DispatchQueue.main.async {
            searchFocused = true
        }
    }

    private func openAgentSettings(_ agent: AgentBrand) {
        state.pendingInspectMemoryID = nil
        state.setupAgent = agent
        state.inspectorPresented = false
        state.selection = .settings
    }

    private func inspectDormantMemories() {
        state.pendingInspectMemoryID = nil
        state.memoryDisplayMode = .list
        model.query = ""
        model.projectFilter = false
        state.filterDormantOnly = true
        state.inspectorPresented = false
        state.selection = .memory
    }

    private func openMemoryGalaxy() {
        state.pendingInspectMemoryID = nil
        state.filterDormantOnly = false
        state.memoryDisplayMode = .galaxy
        state.inspectorPresented = false
        state.selection = .memory
        model.refreshMemoryGraph()
    }

    private func inspectMemory(id memoryID: String) {
        if let hit = model.hits.first(where: { $0.id == memoryID }) {
            model.show(hit)
            state.inspectorPresented = true
            return
        }
        if let directMemory = try? model.memory(id: memoryID, version: nil) {
            let hit = SearchHit(memory: directMemory, vector: nil, keywordRank: nil, score: 0)
            model.show(hit)
            state.inspectorPresented = true
            return
        }
        state.pendingInspectMemoryID = memoryID
        model.query = ""
        model.projectFilter = false
        model.find()
        state.inspectorPresented = true
    }
}
