import AgentMemoryCore
import SwiftUI

private enum OverviewStackCard: Int, CaseIterable, Identifiable {
    case hub = 0
    case agents = 1
    case health = 2

    var id: Int { rawValue }
}

private struct DuplicateComparisonItem: Identifiable {
    let id: String
    let memoryA: Memory
    let memoryB: Memory
    let similarity: Double
}

@MainActor
private final class OverviewUIState: ObservableObject {
    @Published var searchDraft = ""
    @Published var expandedCard: OverviewStackCard = .hub
    @Published var showAddAgentHint = false
    @Published var comparingDuplicate: DuplicateComparisonItem?
    @Published var dreamCopiedConfirmation = false

    var hoverSwitchTask: Task<Void, Never>?
    var dreamConfirmationTask: Task<Void, Never>?

    func scheduleFocus(_ card: OverviewStackCard) {
        hoverSwitchTask?.cancel()
        guard expandedCard != card else { return }
        hoverSwitchTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(65)) }
            catch { return }
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.36, dampingFraction: 0.72)) {
                self?.expandedCard = card
            }
        }
    }

    func focusImmediately(_ card: OverviewStackCard) {
        hoverSwitchTask?.cancel()
        withAnimation(.spring(response: 0.36, dampingFraction: 0.72)) {
            expandedCard = card
        }
    }

    func triggerDreamConfirmation() {
        dreamConfirmationTask?.cancel()
        withAnimation(.spring(response: 0.34, dampingFraction: 0.76)) {
            dreamCopiedConfirmation = true
        }
        dreamConfirmationTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(2500)) }
            catch { return }
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.36, dampingFraction: 0.78)) {
                self?.dreamCopiedConfirmation = false
            }
        }
    }
}

struct OverviewView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var model: AppModel
    @Binding var selection: AppPage
    let isSidebarExpanded: Bool
    let onSearchMemory: (String) -> Void
    let onInspectMemoryID: (String) -> Void
    let onOpenAgentSettings: (AgentBrand) -> Void
    let onInspectDormantMemories: () -> Void
    let onOpenGalaxy: () -> Void
    let onTriggerDreamResonance: () -> Void
    let onNonDetailAction: () -> Void

    @StateObject private var ui = OverviewUIState()

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 1. Mid-Left Floating Liquid Glass Search + 3 Stacked Q-Bounce Cards
            // Right-hand open space remains completely unobstructed & interactive for the 3D Galaxy behind.
            leftFloatingStack
                .frame(width: 314)
                .padding(.leading, 18)
                .padding(.top, 14)
                .padding(.bottom, 22)
                .rotation3DEffect(
                    .degrees(isSidebarExpanded ? -12 : 0),
                    axis: (x: 0, y: 1, z: 0),
                    anchor: .trailing,
                    perspective: 0.45
                )
                .offset(x: isSidebarExpanded ? 72 : 0)
                .scaleEffect(isSidebarExpanded ? 0.93 : 1.0, anchor: .trailing)
                .opacity(isSidebarExpanded ? 0.64 : 1.0)
                .blur(radius: isSidebarExpanded ? 0.8 : 0)
                .animation(.spring(response: 0.36, dampingFraction: 0.78), value: isSidebarExpanded)

            // 2. Right-Hand Bottom-Centered Floating "批量做梦" Nebula Iridescent Main Capsule
            VStack {
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: 332, height: 1)
                        .allowsHitTesting(false)
                    Spacer(minLength: 0)
                    DreamResonanceCapsule(
                        pendingCount: model.dashboard?.pending ?? 0,
                        hasQueuedBatch: model.dashboard?.queuedThrough != nil,
                        isCopiedConfirmation: ui.dreamCopiedConfirmation
                    ) {
                        handleBatchDreamTap()
                    }
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 26)
                .padding(.trailing, 18)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $ui.showAddAgentHint) {
            addAgentPlaceholderSheet
        }
        .sheet(item: $ui.comparingDuplicate) { pair in
            DuplicatePairComparisonSheet(
                pair: pair,
                onInspectMemory: { memoryID in
                    ui.comparingDuplicate = nil
                    onInspectMemoryID(memoryID)
                },
                onClose: {
                    ui.comparingDuplicate = nil
                }
            )
            .applyTheme(model.themeMode)
        }
    }

    private func handleBatchDreamTap() {
        onNonDetailAction()
        if model.dashboard?.queuedThrough != nil {
            model.copyBatchDream()
        } else {
            model.copyDreamInstructions()
        }
        ui.triggerDreamConfirmation()
        onTriggerDreamResonance()
    }

    // MARK: - Mid-Left Floating Stack

    private var leftFloatingStack: some View {
        VStack(alignment: .leading, spacing: 12) {
            standaloneSearchBar

            VStack(alignment: .leading, spacing: 10) {
                memoryHubCard
                connectedAgentsCard
                memoryHealthCard
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Pure Standalone Liquid Glass Search Box (No Dream CTA Inside)

    private var standaloneSearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.textSecondary)

            TextField("搜索长期记忆…", text: $ui.searchDraft)
                .textFieldStyle(.plain)
                .font(.callout)
                .foregroundStyle(theme.textPrimary)
                .onSubmit {
                    submitOverviewSearch()
                }

            if !ui.searchDraft.isEmpty {
                Button {
                    ui.searchDraft = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(theme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空搜索输入")
            } else {
                Text("⌘F")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(theme.surfaceSecondary.opacity(theme.isDark ? 0.55 : 0.72), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(theme.hairlineBorder, lineWidth: 0.8)
                    )
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .liquidGlassSurface(cornerRadius: 14)
    }

    private func submitOverviewSearch() {
        let query = ui.searchDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        onSearchMemory(query)
        ui.searchDraft = ""
    }

    // MARK: - Card 1 (Default Expanded): Memory Hub

    private var memoryHubCard: some View {
        let isExpanded = ui.expandedCard == .hub
        let activeCount = model.dashboard?.memories ?? model.healthSummary.activeCount
        let pendingCount = model.dashboard?.pending ?? 0
        let reviewCount = model.dashboard?.review ?? 0
        let clusterCount = MemoryGalaxyView.clusterCount(for: model.memoryGraph)
        let runtime = model.overallRuntimeStatus

        return VStack(alignment: .leading, spacing: isExpanded ? 12 : 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 24, height: 24)
                    .background(theme.accentSoft, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                Text("记忆中枢")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(theme.textPrimary)

                Spacer(minLength: 4)

                if isExpanded {
                    StatusCapsule(title: runtime.title, kind: runtime.kind, showSpinner: runtime.spinning)
                        .scaleEffect(0.88, anchor: .trailing)
                } else {
                    HStack(spacing: 6) {
                        Text("活跃 \(activeCount)")
                            .foregroundStyle(theme.textPrimary)
                        Text("·")
                            .foregroundStyle(theme.textTertiary)
                        Text("待审 \(pendingCount + reviewCount)")
                            .foregroundStyle((pendingCount + reviewCount) > 0 ? theme.warning : theme.textSecondary)
                    }
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                }
            }

            if isExpanded {
                HStack(spacing: 8) {
                    hubStatTile(title: "今日召回", value: "\(model.todayRecallCount)", tint: theme.accent) {
                        selection = .activity
                    }
                    hubStatTile(title: "估算 Token", value: "~\(model.todayRecallEstimatedTokens.formatted(.number))", tint: theme.info) {
                        selection = .activity
                    }
                    hubStatTile(title: "语义星系", value: "\(clusterCount)", tint: theme.scopeGlobal) {
                        onOpenGalaxy()
                    }
                }

                Divider().overlay(theme.hairlineBorder)

                HStack(spacing: 8) {
                    hubQuickPill(label: "活跃记忆", count: activeCount, tint: theme.accent) {
                        selection = .memory
                    }
                    hubQuickPill(label: "待做梦", count: pendingCount, tint: theme.info) {
                        selection = .dream
                    }
                    hubQuickPill(label: "待确认", count: reviewCount, tint: reviewCount > 0 ? theme.warning : theme.success) {
                        selection = .dream
                    }
                }

                HStack(spacing: 6) {
                    Circle()
                        .fill(model.runtimeHealth.embedding.presentation.kind.color(in: theme))
                        .frame(width: 6, height: 6)
                    Text(model.runtimeHealth.embedding.presentation.detail)
                        .font(.caption2)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button {
                        onOpenGalaxy()
                    } label: {
                        HStack(spacing: 3) {
                            Text("全屏星图")
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(theme.accent)
                    }
                    .buttonStyle(.plain)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(isExpanded ? 14 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassSurface(cornerRadius: 16, highlighted: isExpanded)
        .scaleEffect(isExpanded ? 1.018 : 0.985)
        .opacity(isExpanded ? 1.0 : 0.84)
        .zIndex(isExpanded ? 3 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onHover { hovering in
            if hovering { ui.scheduleFocus(.hub) }
        }
        .onTapGesture {
            if !isExpanded { ui.focusImmediately(.hub) }
        }
    }

    private func hubStatTile(title: String, value: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(value)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(theme.surfaceSecondary.opacity(theme.isDark ? 0.52 : 0.70), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(theme.hairlineBorder, lineWidth: 0.9)
            )
        }
        .buttonStyle(.plain)
    }

    private func hubQuickPill(label: String, count: Int, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(theme.textSecondary)
                Text("\(count)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(tint.opacity(theme.isDark ? 0.12 : 0.08), in: Capsule())
            .overlay(Capsule().stroke(tint.opacity(0.24), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Card 2: Connected Agents

    private var connectedAgentsCard: some View {
        let isExpanded = ui.expandedCard == .agents
        let codexOnline = model.connection?.toolsAvailable == true || model.enabled
        let agyOnline = model.antigravityConnection?.toolsAvailable == true || model.antigravityEnabled

        return VStack(alignment: .leading, spacing: isExpanded ? 10 : 0) {
            HStack(spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.agentAntigravity)
                    .frame(width: 24, height: 24)
                    .background(theme.agentAntigravitySoft, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                Text("已接入 Agent")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(theme.textPrimary)

                Spacer(minLength: 4)

                HStack(spacing: 8) {
                    agentStatusDot(brand: .codex, active: codexOnline)
                    agentStatusDot(brand: .antigravity, active: agyOnline)
                }
            }

            if isExpanded {
                VStack(spacing: 8) {
                    compactAgentRow(
                        brand: .codex,
                        connected: model.connection?.toolsAvailable == true,
                        captureEnabled: model.enabled,
                        captureState: model.runtimeHealth.codexCapture,
                        recallActive: model.recallEnabled && model.connection?.recallInstalled == true,
                        isScanning: model.scanning,
                        onScan: { Task { await model.scan(force: true) } },
                        onOpenSettings: { onOpenAgentSettings(.codex) }
                    )

                    compactAgentRow(
                        brand: .antigravity,
                        connected: model.antigravityConnection?.toolsAvailable == true,
                        captureEnabled: model.antigravityEnabled,
                        captureState: model.runtimeHealth.antigravityCapture,
                        recallActive: model.antigravityRecallEnabled && model.antigravityConnection?.recallInstalled == true,
                        isScanning: model.antigravityScanning,
                        onScan: { Task { await model.scanAntigravity(force: true) } },
                        onOpenSettings: { onOpenAgentSettings(.antigravity) }
                    )

                    Button {
                        onNonDetailAction()
                        ui.showAddAgentHint = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .semibold))
                            Text("接入更多 Agent")
                                .font(.caption.weight(.medium))
                            Spacer()
                            Text("Claude Code · Cursor")
                                .font(.caption2)
                                .foregroundStyle(theme.textTertiary)
                        }
                        .foregroundStyle(theme.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            theme.surfaceSecondary.opacity(theme.isDark ? 0.35 : 0.50),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(theme.strongBorder, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        )
                    }
                    .buttonStyle(.plain)
                    .help("查看已支持的 Agent 与后续扩展计划")
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(isExpanded ? 14 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassSurface(cornerRadius: 16, highlighted: isExpanded)
        .scaleEffect(isExpanded ? 1.018 : 0.985)
        .opacity(isExpanded ? 1.0 : 0.84)
        .zIndex(isExpanded ? 3 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onHover { hovering in
            if hovering { ui.scheduleFocus(.agents) }
        }
        .onTapGesture {
            if !isExpanded { ui.focusImmediately(.agents) }
        }
    }

    private func agentStatusDot(brand: AgentBrand, active: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(active ? brand.color(in: theme) : theme.textTertiary.opacity(0.45))
                .frame(width: 6.5, height: 6.5)
                .shadow(color: active ? brand.color(in: theme).opacity(0.65) : .clear, radius: 3)
            Text(brand.rawValue)
                .font(.caption2.weight(.medium))
                .foregroundStyle(active ? theme.textPrimary : theme.textTertiary)
        }
    }

    private func compactAgentRow(
        brand: AgentBrand,
        connected: Bool,
        captureEnabled: Bool,
        captureState: RuntimeHealth.CaptureState,
        recallActive: Bool,
        isScanning: Bool,
        onScan: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void
    ) -> some View {
        let isCapturing = captureState == .idle || captureState == .scanning
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                AgentTag(agent: brand, active: connected || isCapturing)
                Spacer(minLength: 4)
                Button(action: onScan) {
                    HStack(spacing: 4) {
                        if isScanning {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 9.5, weight: .semibold))
                        }
                        Text(isScanning ? "扫描中" : "立即扫描")
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(captureEnabled && !isScanning ? theme.textPrimary : theme.textTertiary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3.5)
                    .background(theme.surfacePrimary.opacity(theme.isDark ? 0.55 : 0.78), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(theme.hairlineBorder, lineWidth: 0.9)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!captureEnabled || isScanning || model.store == nil)
                .help(captureEnabled ? "立即扫描 \(brand.rawValue) 新对话" : "请先在设置中启用 \(brand.rawValue) 采集")

                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 22, height: 22)
                        .background(theme.surfacePrimary.opacity(theme.isDark ? 0.55 : 0.78), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(theme.hairlineBorder, lineWidth: 0.9)
                        )
                }
                .buttonStyle(.plain)
                .help("前往设置配置 \(brand.rawValue) 连接与自动检索")
                .accessibilityLabel("\(brand.rawValue) 连接设置")
            }

            HStack(spacing: 10) {
                miniLight("MCP", ok: connected)
                miniLight("采集", ok: isCapturing)
                miniLight("自动注入", ok: recallActive)
                Spacer(minLength: 0)
            }
        }
        .padding(9)
        .background(theme.surfaceSecondary.opacity(theme.isDark ? 0.50 : 0.68), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.hairlineBorder, lineWidth: 0.9)
        )
    }

    private func miniLight(_ label: String, ok: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(ok ? theme.success : theme.textTertiary.opacity(0.45))
                .frame(width: 5.5, height: 5.5)
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(ok ? theme.textPrimary : theme.textTertiary)
        }
    }

    // MARK: - Card 3: Memory Health

    private var memoryHealthCard: some View {
        let isExpanded = ui.expandedCard == .health
        let health = model.healthSummary
        let total = max(health.activeCount + health.archivedCount, 0)
        let activeRatio = total > 0 ? Double(health.activeCount) / Double(total) : 1.0
        let activePercent = Int((activeRatio * 100).rounded())
        let needsAttention = !health.dormantMemoryIDs.isEmpty || !health.duplicatePairs.isEmpty

        return VStack(alignment: .leading, spacing: isExpanded ? 10 : 0) {
            HStack(spacing: 8) {
                Image(systemName: "heart.text.square")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(needsAttention ? theme.warning : theme.success)
                    .frame(width: 24, height: 24)
                    .background(needsAttention ? theme.warningSoft : theme.successSoft, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                Text("记忆健康度")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(theme.textPrimary)

                Spacer(minLength: 4)

                if isExpanded {
                    Button {
                        model.refreshHealthSummary()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("刷新记忆健康体检")
                } else {
                    Text("活跃 \(activePercent)% · \(needsAttention ? "待整理" : "良好")")
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(needsAttention ? theme.warning : theme.success)
                }
            }

            if isExpanded {
                // Active / Archived bar
                VStack(alignment: .leading, spacing: 6) {
                    GeometryReader { proxy in
                        let width = max(proxy.size.width, 1)
                        ZStack(alignment: .leading) {
                            Capsule().fill(theme.surfaceSecondary)
                            Capsule()
                                .fill(theme.accent)
                                .frame(width: total > 0 ? max(width * activeRatio, health.activeCount > 0 ? 6 : 0) : 0)
                        }
                    }
                    .frame(height: 7)

                    HStack(spacing: 12) {
                        HStack(spacing: 4) {
                            Circle().fill(theme.accent).frame(width: 6, height: 6)
                            Text("活跃 \(health.activeCount)")
                                .font(.caption2.weight(.medium))
                                .monospacedDigit()
                                .foregroundStyle(theme.textPrimary)
                        }
                        HStack(spacing: 4) {
                            Circle().fill(theme.textTertiary.opacity(0.45)).frame(width: 6, height: 6)
                            Text("归档 \(health.archivedCount)")
                                .font(.caption2.weight(.medium))
                                .monospacedDigit()
                                .foregroundStyle(theme.textSecondary)
                        }
                        Spacer()
                        Text("\(activePercent)%")
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(theme.accent)
                    }
                }

                // Dormant jump row
                Button {
                    if !health.dormantMemoryIDs.isEmpty {
                        onInspectDormantMemories()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "moon.zzz")
                            .font(.caption)
                            .foregroundStyle(health.dormantMemoryIDs.isEmpty ? theme.success : theme.warning)
                        Text("沉睡记忆")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                        Text("\(health.dormantMemoryIDs.count) 条")
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(health.dormantMemoryIDs.isEmpty ? theme.success : theme.warning)
                        if !health.dormantMemoryIDs.isEmpty {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(theme.accent)
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(theme.surfaceSecondary.opacity(theme.isDark ? 0.50 : 0.68), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(theme.hairlineBorder, lineWidth: 0.9)
                    )
                }
                .buttonStyle(.plain)
                .disabled(health.dormantMemoryIDs.isEmpty)

                // Suspected duplicates side-by-side entry
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("疑似重复", systemImage: "square.on.square")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(theme.textSecondary)
                        Spacer()
                        Text("\(health.duplicatePairs.count) 对")
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(health.duplicatePairs.isEmpty ? theme.success : theme.warning)
                    }

                    if health.duplicatePairs.isEmpty {
                        Text("活跃记忆语义分布良好，未发现高相似重复对。")
                            .font(.caption2)
                            .foregroundStyle(theme.textTertiary)
                    } else {
                        ForEach(Array(health.duplicatePairs.prefix(2).enumerated()), id: \.offset) { _, pair in
                            let memA = resolveMemory(id: pair.memoryAID)
                            let memB = resolveMemory(id: pair.memoryBID)
                            Button {
                                guard let memA, let memB else { return }
                                onNonDetailAction()
                                ui.comparingDuplicate = DuplicateComparisonItem(
                                    id: "\(pair.memoryAID)-\(pair.memoryBID)",
                                    memoryA: memA,
                                    memoryB: memB,
                                    similarity: pair.similarity
                                )
                            } label: {
                                HStack(spacing: 6) {
                                    Text("\(Int((pair.similarity * 100).rounded()))%")
                                        .font(.caption2.weight(.semibold))
                                        .monospacedDigit()
                                        .foregroundStyle(theme.warning)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(theme.warningSoft, in: Capsule())
                                    Text(memA?.title ?? String(pair.memoryAID.prefix(8)))
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(theme.textPrimary)
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text("对比")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(theme.accent)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(theme.surfaceSecondary.opacity(theme.isDark ? 0.50 : 0.68), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(theme.hairlineBorder, lineWidth: 0.9)
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(memA == nil || memB == nil)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(isExpanded ? 14 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassSurface(cornerRadius: 16, highlighted: isExpanded)
        .scaleEffect(isExpanded ? 1.018 : 0.985)
        .opacity(isExpanded ? 1.0 : 0.84)
        .zIndex(isExpanded ? 3 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onHover { hovering in
            if hovering { ui.scheduleFocus(.health) }
        }
        .onTapGesture {
            if !isExpanded { ui.focusImmediately(.health) }
        }
    }

    private func resolveMemory(id: String) -> Memory? {
        if let hit = model.hits.first(where: { $0.id == id }) {
            return hit.memory
        }
        return try? model.memory(id: id, version: nil)
    }

    // MARK: - Add Agent Placeholder Sheet

    private var addAgentPlaceholderSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("接入更多 Agent")
                        .font(.headline)
                        .foregroundStyle(theme.textPrimary)
                    Text("跨 Agent 记忆生态扩展入口")
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                }
            }

            Text("当前已支持 Codex 与 Antigravity 的 MCP 接入、增量采集与对话前自动检索。更多 Agent（如 Claude Code、Cursor 等）适配正在开发中，后续可在此直接选择 Agent 并引导一键接入。")
                .font(.callout)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                AgentTag(agent: .codex, active: true)
                AgentTag(agent: .antigravity, active: true)
                Spacer()
                Button("前往设置") {
                    ui.showAddAgentHint = false
                    onOpenAgentSettings(.codex)
                }
                .buttonStyle(SoftActionButtonStyle())
                Button("知道了") {
                    ui.showAddAgentHint = false
                }
                .buttonStyle(PrimaryActionButtonStyle())
            }
        }
        .padding(22)
        .frame(width: 400)
        .applyTheme(model.themeMode)
    }
}

// MARK: - Standalone "批量做梦" Apple Intelligence–Style Iridescent Nebula Capsule

private struct DreamResonanceCapsule: View {
    @Environment(\.theme) private var theme
    let pendingCount: Int
    let hasQueuedBatch: Bool
    let isCopiedConfirmation: Bool
    let action: () -> Void

    @StateObject private var hovered = LocalState(false)

    private var subtitleText: String {
        if pendingCount > 0 {
            return "待整理 \(pendingCount) 条新线索 · 点击复制"
        }
        if hasQueuedBatch {
            return "有待整理对话 · 点击复制"
        }
        return "复制指令 · 整理记忆"
    }

    var body: some View {
        let isHovered = hovered.value
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let angle = Angle.degrees((t * (isHovered ? 115 : 44)).truncatingRemainder(dividingBy: 360))
            let breathe = 0.88 + 0.12 * sin(t * 2.4)

            Button(action: action) {
                HStack(spacing: 12) {
                    // Breathing crescent + sparkle icon
                    ZStack {
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [
                                        (isCopiedConfirmation ? theme.success : theme.accent).opacity(theme.isDark ? 0.34 : 0.22),
                                        Color.clear
                                    ],
                                    center: .center,
                                    startRadius: 2,
                                    endRadius: 20
                                )
                            )
                            .frame(width: 34, height: 34)
                            .scaleEffect(breathe)

                        Image(systemName: isCopiedConfirmation ? "checkmark.circle.fill" : "moon.stars.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(
                                isCopiedConfirmation
                                    ? AnyShapeStyle(theme.success)
                                    : AnyShapeStyle(
                                        LinearGradient(
                                            colors: [theme.accent, theme.agentAntigravity],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                            )
                    }

                    if isCopiedConfirmation {
                        Text("✓ 做梦指令已复制 · 粘贴到 Agent 继续")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    } else {
                        VStack(alignment: .leading, spacing: 1.5) {
                            HStack(spacing: 6) {
                                Text("批量做梦")
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(theme.textPrimary)
                                if pendingCount > 0 {
                                    Text("\(pendingCount)")
                                        .font(.caption2.weight(.bold))
                                        .monospacedDigit()
                                        .foregroundStyle(theme.accent)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1.5)
                                        .background(theme.accentSoft, in: Capsule())
                                }
                            }
                            Text(subtitleText)
                                .font(.caption2)
                                .foregroundStyle(theme.textSecondary)
                                .lineLimit(1)
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))

                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 10, weight: .semibold))
                            Text("复制")
                                .font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(theme.accentSoft, in: Capsule())
                        .overlay(Capsule().stroke(theme.accentBorder, lineWidth: 0.8))
                    }
                }
                .padding(.leading, 12)
                .padding(.trailing, isCopiedConfirmation ? 18 : 13)
                .padding(.vertical, 9)
                .background {
                    ZStack {
                        Capsule().fill(.ultraThinMaterial)
                        Capsule().fill(theme.glassTint)
                    }
                }
                .overlay {
                    // Apple Intelligence–style flowing teal ↔ cyan ↔ indigo ↔ violet thin luminous edge
                    Capsule()
                        .strokeBorder(
                            AngularGradient(
                                gradient: Gradient(colors: isCopiedConfirmation
                                    ? [theme.success, theme.accent, theme.success]
                                    : [
                                        theme.accent,
                                        theme.info,
                                        theme.agentAntigravity,
                                        theme.scopeGlobal,
                                        theme.accent
                                    ]
                                ),
                                center: .center,
                                angle: angle
                            ),
                            lineWidth: isHovered ? 2.0 : 1.5
                        )
                }
                .shadow(
                    color: (isCopiedConfirmation ? theme.success : theme.accent).opacity(theme.isDark ? (isHovered ? 0.34 : 0.20) : (isHovered ? 0.24 : 0.14)),
                    radius: isHovered ? 20 : 13,
                    y: isHovered ? 8 : 5
                )
                .shadow(color: theme.glassShadow, radius: 10, y: 4)
            }
            .buttonStyle(.plain)
            .scaleEffect(isHovered ? 1.035 : 1.0)
            .offset(y: isHovered ? -2 : 0)
            .animation(.spring(response: 0.34, dampingFraction: 0.72), value: isHovered)
            .onHover { hovered.value = $0 }
            .help("复制批量做梦指令到剪贴板，粘贴到 Agent 中整理近期对话为长期记忆")
        }
    }
}

// MARK: - Duplicate Pair Comparison Sheet

private struct DuplicatePairComparisonSheet: View {
    @Environment(\.theme) private var theme
    let pair: DuplicateComparisonItem
    let onInspectMemory: (String) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "square.on.square")
                    .font(.title3)
                    .foregroundStyle(theme.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text("疑似重复记忆对比")
                        .font(.headline)
                        .foregroundStyle(theme.textPrimary)
                    Text("两条记忆语义高度接近，可在检查器中查看原始证据后决定是否合并或归档。")
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer()
                ScorePill(
                    label: "向量相似度",
                    value: "\(Int((pair.similarity * 100).rounded()))%",
                    tint: theme.warning
                )
            }

            HStack(alignment: .top, spacing: 12) {
                memoryPane(pair.memoryA, label: "记忆 A")
                memoryPane(pair.memoryB, label: "记忆 B")
            }

            HStack {
                Spacer()
                Button("关闭", action: onClose)
                    .buttonStyle(SoftActionButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 720, height: 420)
        .background(theme.canvasBackground)
    }

    private func memoryPane(_ memory: Memory, label: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.accent)
                ScopeTag(projectPath: memory.project)
                ScorePill(label: "v", value: "\(memory.version)")
                ScorePill(label: "命中", value: "\(memory.hitCount) 次", tint: memory.hitCount > 0 ? theme.warning : theme.textTertiary)
                Spacer()
            }

            Text(memory.title)
                .font(.headline)
                .foregroundStyle(theme.textPrimary)
                .textSelection(.enabled)

            Text("更新于 " + Date(timeIntervalSince1970: memory.updated).formatted(.dateTime.year().month().day().hour().minute()))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(theme.textTertiary)

            ScrollView {
                Text(memory.body)
                    .font(.callout)
                    .foregroundStyle(theme.textPrimary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button {
                    onInspectMemory(memory.id)
                } label: {
                    Label("在检查器查看", systemImage: "sidebar.right")
                }
                .buttonStyle(SoftActionButtonStyle(tint: theme.accent, compact: true))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .surfaceCard(cornerRadius: 11, padding: 13)
    }
}
