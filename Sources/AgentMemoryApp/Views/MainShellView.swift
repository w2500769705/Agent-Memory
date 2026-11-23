import AgentMemoryCore
import AppKit
import SwiftUI

@MainActor
private final class ShellState: ObservableObject {
    @Published var selection: AppPage = .overview
    @Published var setupAgent: AgentBrand = .codex
    @Published var memoryDisplayMode: MemoryDisplayMode = .list
    @Published var memoryReviewMode: MemoryReviewMode = .standard
    @Published var pendingActivityFilter: ActivityEventFilter?
    @Published var focusDreamProposals = false
    @Published var pickedDecision: Decision?
    @Published var pendingUndo: String?
    @Published var showBackfill = false
    @Published var backfillDate = Calendar.current.startOfDay(for: Date())
    @Published var inspectorPresented = false
    @Published var inspectorWidth: CGFloat = 0
    @Published var isHoveringInspectorResize = false
    @Published var isDraggingInspectorResize = false
    @Published var pendingInspectMemoryID: String?
    @Published var sidebarExpanded = false
    @Published var hoveredPage: AppPage? = nil
    @Published var dreamResonanceTrigger: Date? = nil
    @Published var isWindowRenderingActive = true

    var inspectorDragStartWidth: CGFloat? = nil
    private var resizeCursorPushed = false
    private var sidebarCollapseTask: Task<Void, Never>?

    func updateResizeCursor() {
        let shouldShow = isHoveringInspectorResize || isDraggingInspectorResize
        if shouldShow && !resizeCursorPushed {
            NSCursor.resizeLeftRight.push()
            resizeCursorPushed = true
        } else if !shouldShow && resizeCursorPushed {
            NSCursor.pop()
            resizeCursorPushed = false
        }
    }

    func setSidebarHovered(_ hovering: Bool) {
        sidebarCollapseTask?.cancel()
        if hovering {
            if !sidebarExpanded {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    sidebarExpanded = true
                }
            }
        } else {
            sidebarCollapseTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.22)) {
                    self?.sidebarExpanded = false
                    self?.hoveredPage = nil
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

    private var isGalaxyActive: Bool {
        state.selection == .overview || isFullScreenGalaxy
    }

    private func resolvedInspectorWidth(for windowWidth: CGFloat) -> CGFloat {
        let defaultWidth = min(max(440, windowWidth * 0.40), 620)
        let targetWidth = state.inspectorWidth > 0 ? state.inspectorWidth : defaultWidth
        let maxAllowed = max(480, windowWidth * 0.65)
        let clamped = min(max(targetWidth, 320), maxAllowed)
        let narrowGuard = max(300, windowWidth - 280)
        return min(clamped, narrowGuard)
    }

    var body: some View {
        GeometryReader { windowProxy in
            let windowWidth = windowProxy.size.width
            let drawerWidth = resolvedInspectorWidth(for: windowWidth)

            ZStack(alignment: .leading) {
                // Layer 0: Borderless Full-Window 3D Elastic Memory Galaxy (auto-paused on non-galaxy pages or inactive/occluded window)
                MemoryGalaxyView(
                    model: model,
                    mode: isFullScreenGalaxy ? .interactiveFull : .ambientBackdrop,
                    isPaused: !isGalaxyActive || !state.isWindowRenderingActive,
                    isSidebarExpanded: state.sidebarExpanded,
                    dreamResonanceTrigger: state.dreamResonanceTrigger,
                    onSelectMemoryID: { memoryID in
                        inspectMemory(id: memoryID)
                    },
                    onClearSelection: {
                        clearSelection()
                    }
                )
                .ignoresSafeArea()

                // Layer 1: Top 62pt Native Window Drag & Double-Click Zoom Region
                WindowDragRegion()
                    .frame(maxWidth: .infinity)
                    .frame(height: 62)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea(edges: .top)

                // Layer 2: Spatial Content Area + Resizable Liquid Glass Inspector Drawer
                VStack(spacing: 0) {
                    if let error = model.error {
                        ErrorBanner(message: error) {
                            model.error = nil
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                    }

                    HStack(spacing: 0) {
                        contentLayer
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        if state.inspectorPresented {
                            inspectorResizeHandle(windowWidth: windowWidth, currentWidth: drawerWidth)

                            InspectorView(
                                model: model,
                                selection: state.selection,
                                pickedDecision: $state.pickedDecision,
                                onClose: { clearSelection() }
                            )
                            .frame(width: drawerWidth)
                            .frame(maxHeight: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .liquidGlassSurface(cornerRadius: 20, panel: true)
                            .padding(.top, 6)
                            .padding(.bottom, 16)
                            .padding(.trailing, 16)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .animation(.spring(response: 0.30, dampingFraction: 0.82), value: state.inspectorPresented)
                }
                .padding(.leading, 68)

                // Layer 3: Leftmost Floating Hover-Expand Liquid Glass Navigation Rail
                floatingLiquidGlassRail
                    .padding(.leading, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 16)
                    .zIndex(20)
            }
        }
        .frame(minWidth: 860, minHeight: 540)
        .navigationTitle(state.selection.rawValue)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar {
            toolbarContent
        }
        .background {
            ZStack {
                Button("") { focusMemorySearch() }
                    .keyboardShortcut("f", modifiers: .command)
                    .hidden()

                WindowVisibilityObserver { isActive in
                    if state.isWindowRenderingActive != isActive {
                        state.isWindowRenderingActive = isActive
                    }
                }
                .allowsHitTesting(false)
            }
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
                state.focusDreamProposals = false
            }
            if selection != .activity {
                state.pendingActivityFilter = nil
            }
            if selection != .memory {
                state.memoryReviewMode = .standard
            }
            // Auto-collapse right inspector on tab switch unless triggered by a pending inspect-memory jump.
            if state.pendingInspectMemoryID == nil {
                state.inspectorPresented = false
            }
            if selection == .memory && state.memoryDisplayMode == .galaxy {
                model.refreshMemoryGraph()
            }
        }
        .onChange(of: state.memoryDisplayMode) { previousMode, mode in
            if previousMode == .archived || mode == .archived {
                state.inspectorPresented = false
            }
            if mode == .galaxy { model.refreshMemoryGraph() }
        }
        .onChange(of: model.selectedMemory?.id) { previousID, currentID in
            if state.selection == .memory, state.memoryDisplayMode == .archived,
               previousID != nil, currentID == nil {
                clearSelection()
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
        .onChange(of: state.inspectorPresented) { _, isPresented in
            if !isPresented {
                model.selectedMemory = nil
                state.pickedDecision = nil
                state.isHoveringInspectorResize = false
                state.isDraggingInspectorResize = false
                state.inspectorDragStartWidth = nil
                state.updateResizeCursor()
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
                isAnimationsPaused: !state.isWindowRenderingActive,
                onSearchMemory: { query in searchFromOverview(query) },
                onInspectMemoryID: { memoryID in inspectMemory(id: memoryID) },
                onOpenAgentSettings: { agent in openAgentSettings(agent) },
                onReviewMemories: { mode in openMemoryReview(mode) },
                onOpenArchivedMemories: { openArchivedMemories() },
                onOpenRecallActivity: {
                    state.pendingActivityFilter = .recall
                    state.selection = .activity
                },
                onOpenDreamProposals: {
                    state.focusDreamProposals = true
                    state.selection = .dream
                },
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
                        label: { $0.label(archivedCount: model.healthSummary.archivedCount) },
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
                    .degrees(state.sidebarExpanded ? -7 : 0),
                    axis: (x: 0, y: 1, z: 0),
                    anchor: .trailing,
                    perspective: 0.45
                )
                .offset(x: state.sidebarExpanded ? 16 : 0)
                .scaleEffect(state.sidebarExpanded ? 0.95 : 1.0, anchor: .trailing)
                .animation(
                    state.sidebarExpanded
                        ? .spring(response: 0.32, dampingFraction: 0.82)
                        : .easeOut(duration: 0.22),
                    value: state.sidebarExpanded
                )
        }
    }

    private func inspectorResizeHandle(windowWidth: CGFloat, currentWidth: CGFloat) -> some View {
        let active = state.isHoveringInspectorResize || state.isDraggingInspectorResize
        return ZStack {
            Capsule()
                .fill(active ? theme.accent.opacity(theme.isDark ? 0.78 : 0.68) : theme.hairlineBorder.opacity(0.65))
                .frame(width: active ? 3.5 : 2.5, height: active ? 56 : 34)
                .shadow(color: active ? theme.accent.opacity(0.45) : .clear, radius: 5)
                .animation(.easeOut(duration: 0.14), value: active)
        }
        .frame(width: 8)
        .frame(maxHeight: .infinity)
        .padding(.top, 6)
        .padding(.bottom, 16)
        .contentShape(Rectangle())
        .onHover { hovering in
            state.isHoveringInspectorResize = hovering
            state.updateResizeCursor()
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if state.inspectorDragStartWidth == nil {
                        state.inspectorDragStartWidth = currentWidth
                        state.isDraggingInspectorResize = true
                        state.updateResizeCursor()
                    }
                    let proposed = (state.inspectorDragStartWidth ?? currentWidth) - value.translation.width
                    let maxAllowed = max(480, windowWidth * 0.65)
                    let narrowGuard = max(300, windowWidth - 280)
                    state.inspectorWidth = min(min(max(proposed, 320), maxAllowed), narrowGuard)
                }
                .onEnded { _ in
                    state.inspectorDragStartWidth = nil
                    state.isDraggingInspectorResize = false
                    state.updateResizeCursor()
                }
        )
        .help("拖动调整详情抽屉宽度")
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
                reviewMode: $state.memoryReviewMode,
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
                pendingUndo: $state.pendingUndo,
                focusProposals: $state.focusDreamProposals
            ) { decision in
                state.pickedDecision = decision
                model.show(decision)
                state.inspectorPresented = true
            }
        case .activity:
            ActivityView(model: model, pendingFilter: $state.pendingActivityFilter) { memoryID in
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
                let isHovered = state.hoveredPage == page
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
                                .foregroundStyle(isSelected ? theme.accent : (isHovered ? theme.textPrimary : theme.textSecondary))
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
                                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                                .foregroundStyle(isSelected ? theme.textPrimary : (isHovered ? theme.textPrimary : theme.textSecondary))
                                .lineLimit(1)
                                .transition(.opacity.combined(with: .move(edge: .leading)))

                            Spacer(minLength: 4)

                            if badge > 0 {
                                Text("\(badge)")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(theme.warning)
                                    .padding(.horizontal, 6.5)
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
                            .fill(
                                isSelected
                                    ? theme.accentSoft
                                    : (isHovered
                                        ? (theme.isDark ? Color.white.opacity(0.09) : Color.white.opacity(0.62))
                                        : Color.clear)
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(
                                isSelected
                                    ? theme.accent.opacity(theme.isDark ? 0.42 : 0.34)
                                    : (isHovered
                                        ? (theme.isDark ? Color.white.opacity(0.24) : Color.white.opacity(0.88))
                                        : Color.clear),
                                lineWidth: isSelected ? 1.15 : 1.0
                            )
                    )
                    .shadow(
                        color: isHovered && !isSelected
                            ? (theme.isDark ? Color.black.opacity(0.18) : Color.black.opacity(0.06))
                            : .clear,
                        radius: 6,
                        y: 2
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .animation(.easeOut(duration: 0.14), value: isHovered)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering {
                        state.hoveredPage = page
                    } else if state.hoveredPage == page {
                        state.hoveredPage = nil
                    }
                }
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
                            .font(.system(size: 12, weight: .semibold))
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
                .frame(width: 6, height: 6)
            Text(brand.rawValue)
                .font(.system(size: 11.5, weight: .medium))
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
        if state.selection != .memory || state.memoryDisplayMode != .archived {
            state.memoryDisplayMode = .list
            state.memoryReviewMode = .standard
        }
        state.inspectorPresented = false
        state.selection = .memory
        DispatchQueue.main.async {
            searchFocused = true
        }
    }

    private func searchFromOverview(_ query: String) {
        state.pendingInspectMemoryID = nil
        state.memoryDisplayMode = .list
        state.memoryReviewMode = .standard
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

    private func openMemoryReview(_ mode: MemoryReviewMode) {
        state.pendingInspectMemoryID = nil
        state.memoryDisplayMode = .list
        model.query = ""
        model.projectFilter = false
        state.memoryReviewMode = mode
        state.inspectorPresented = false
        state.selection = .memory
        if mode == .leastUsed { model.refreshMemoryGraph() }
    }

    private func openArchivedMemories() {
        state.pendingInspectMemoryID = nil
        state.memoryReviewMode = .standard
        state.memoryDisplayMode = .archived
        state.inspectorPresented = false
        state.selection = .memory
    }

    private func openMemoryGalaxy() {
        state.pendingInspectMemoryID = nil
        state.memoryReviewMode = .standard
        state.memoryDisplayMode = .galaxy
        state.inspectorPresented = false
        state.selection = .memory
        model.refreshMemoryGraph()
    }

    private func clearSelection() {
        model.selectedMemory = nil
        state.pickedDecision = nil
        if state.inspectorPresented {
            withAnimation(.easeInOut(duration: 0.18)) {
                state.inspectorPresented = false
            }
        }
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

// MARK: - Window Foreground / Occlusion Visibility Observer

private struct WindowVisibilityObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void

    final class ObserverHostView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var lastReported: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attachObservers(for: window)
        }

        func attachObservers(for window: NSWindow?) {
            detachObservers()
            guard let window else { return }

            let center = NotificationCenter.default
            let handler: @Sendable (Notification) -> Void = { [weak self] _ in
                Task { @MainActor in
                    self?.evaluateVisibility()
                }
            }

            let appNotifications: [Notification.Name] = [
                NSApplication.didResignActiveNotification,
                NSApplication.didBecomeActiveNotification,
                NSApplication.didHideNotification,
                NSApplication.didUnhideNotification
            ]
            for name in appNotifications {
                observers.append(center.addObserver(forName: name, object: NSApp, queue: .main, using: handler))
            }

            let windowNotifications: [Notification.Name] = [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification
            ]
            for name in windowNotifications {
                observers.append(center.addObserver(forName: name, object: window, queue: .main, using: handler))
            }

            evaluateVisibility()
        }

        func detachObservers() {
            let center = NotificationCenter.default
            for token in observers {
                center.removeObserver(token)
            }
            observers.removeAll()
        }

        @MainActor
        func evaluateVisibility() {
            guard let window else { return }
            let isActive = NSApp.isActive
                && !NSApp.isHidden
                && !window.isMiniaturized
                && window.occlusionState.contains(.visible)
            if lastReported != isActive {
                lastReported = isActive
                onChange?(isActive)
            }
        }

        deinit {
            detachObservers()
        }
    }

    func makeNSView(context: Context) -> ObserverHostView {
        let view = ObserverHostView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: ObserverHostView, context: Context) {
        nsView.onChange = onChange
    }

    static func dismantleNSView(_ nsView: ObserverHostView, coordinator: ()) {
        nsView.detachObservers()
    }
}
