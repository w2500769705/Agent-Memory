import AgentMemoryCore
import SwiftUI

@MainActor
private final class ShellState: ObservableObject {
    @Published var selection: AppPage = .overview
    @Published var pickedDecision: Decision?
    @Published var pendingUndo: String?
    @Published var showBackfill = false
    @Published var backfillDate = Calendar.current.startOfDay(for: Date())
    @Published var inspectorPresented = false
    @Published var pendingInspectMemoryID: String?
}

struct MainShellView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var model: AppModel
    @StateObject private var state = ShellState()
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 185, ideal: 210, max: 250)
        } detail: {
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    if let error = model.error {
                        ErrorBanner(message: error) {
                            model.error = nil
                        }
                    }
                    pageContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                topToolbarFadeOverlay
            }
            .frame(minWidth: 480)
            .background(theme.canvasBackground, ignoresSafeAreaEdges: .all)
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
        }
        .navigationSplitViewStyle(.balanced)
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
            if selection == .memory {
                model.find()
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
                    Button("开始回填") {
                        model.capture(true, since: state.backfillDate)
                        state.showBackfill = false
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
            .frame(width: 340)
        }
    }

    // MARK: - Top Toolbar Fade Overlay

    private var topToolbarFadeOverlay: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
            LinearGradient(
                stops: [
                    .init(color: theme.canvasBackground.opacity(0.96), location: 0.0),
                    .init(color: theme.canvasBackground.opacity(0.96), location: 0.65),
                    .init(color: theme.canvasBackground.opacity(0.50), location: 0.84),
                    .init(color: theme.canvasBackground.opacity(0.0), location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0.0),
                    .init(color: .black, location: 0.65),
                    .init(color: .black.opacity(0.45), location: 0.84),
                    .init(color: .clear, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .frame(height: 76)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(AppPage.allCases, selection: $state.selection) { page in
            let badge = page.badgeCount(in: model)
            Label(page.rawValue, systemImage: page.icon)
                .tag(page)
                .badge(badge > 0 ? badge : 0)
                .padding(.vertical, 3)
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider().overlay(theme.hairlineBorder)
                sidebarStatusFooter
                    .padding(12)
            }
        }
    }

    private var sidebarStatusFooter: some View {
        let runtime = model.overallRuntimeStatus
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(runtime.kind.color(in: theme))
                    .frame(width: 7, height: 7)
                Text(runtime.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Spacer()
                if runtime.spinning {
                    ProgressView().controlSize(.mini)
                }
            }

            HStack(spacing: 6) {
                AgentTag(agent: .codex, active: model.enabled)
                AgentTag(agent: .antigravity, active: model.antigravityEnabled)
            }
            .scaleEffect(0.92, anchor: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.hairlineBorder, lineWidth: 1)
        )
    }

    // MARK: - Page Content

    @ViewBuilder
    private var pageContent: some View {
        switch state.selection {
        case .overview:
            OverviewView(
                model: model,
                selection: $state.selection,
                onFocusSearch: { focusMemorySearch() },
                onInspectMemoryID: { memoryID in inspectMemory(id: memoryID) }
            )
        case .memory:
            MemoryListView(model: model, searchFocused: $searchFocused) { hit in
                model.show(hit)
                state.inspectorPresented = true
            }
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
            SettingsView(model: model, showBackfill: $state.showBackfill)
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

    private func focusMemorySearch() {
        state.selection = .memory
        DispatchQueue.main.async {
            searchFocused = true
        }
    }

    private func inspectMemory(id memoryID: String) {
        if let hit = model.hits.first(where: { $0.id == memoryID }) {
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
