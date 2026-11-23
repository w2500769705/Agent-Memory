import AgentMemoryCore
import SwiftUI

private enum OverviewStackCard: Int, CaseIterable, Identifiable {
    case hub = 0
    case agents = 1
    case health = 2

    var id: Int { rawValue }
}

private struct DuplicateComparisonItem {
    let memoryA: Memory
    let memoryB: Memory
    let similarity: Double
}

@MainActor
private final class OverviewUIState: ObservableObject {
    @Published var searchDraft = ""
    @Published var expandedCard: OverviewStackCard = .hub
    @Published var showAddAgentHint = false
    @Published var showDuplicateComparison = false
    @Published var confirmDormantArchive = false
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
    var isAnimationsPaused: Bool = false
    let onSearchMemory: (String) -> Void
    let onInspectMemoryID: (String) -> Void
    let onOpenAgentSettings: (AgentBrand) -> Void
    let onReviewMemories: (MemoryReviewMode) -> Void
    let onOpenArchivedMemories: () -> Void
    let onOpenRecallActivity: () -> Void
    let onOpenDreamProposals: () -> Void
    let onOpenGalaxy: () -> Void
    let onTriggerDreamResonance: () -> Void
    let onNonDetailAction: () -> Void

    @StateObject private var ui = OverviewUIState()

    private static let cardExpandTransition: AnyTransition = .asymmetric(
        insertion: .opacity.animation(.easeOut(duration: 0.20).delay(0.05)),
        removal: .opacity.animation(.easeOut(duration: 0.08))
    )

    var body: some View {
        GeometryReader { proxy in
            let availableWidth = proxy.size.width
            let showDreamCapsule = availableWidth >= 380
            let reserveLeftCardSpace = availableWidth >= 680

            ZStack(alignment: .topLeading) {
                // 1. Mid-Left Floating Liquid Glass Search + 3 Stacked Q-Bounce Cards
                // Right-hand open space remains completely unobstructed & interactive for the 3D Galaxy behind.
                leftFloatingStack
                    .padding(.vertical, 14)
                    .padding(.horizontal, 4)
                    .frame(width: 314, alignment: .topLeading)
                    .padding(.leading, 18)
                    .padding(.bottom, showDreamCapsule && !reserveLeftCardSpace ? 114 : 8)
                    .rotation3DEffect(
                        .degrees(isSidebarExpanded ? -12 : 0),
                        axis: (x: 0, y: 1, z: 0),
                        anchor: .trailing,
                        perspective: 0.45
                    )
                    .offset(x: isSidebarExpanded ? 72 : 0)
                    .scaleEffect(isSidebarExpanded ? 0.93 : 1.0, anchor: .trailing)
                    .animation(
                        isSidebarExpanded
                            ? .spring(response: 0.32, dampingFraction: 0.82)
                            : .easeOut(duration: 0.22),
                        value: isSidebarExpanded
                    )

                // 2. Adaptive Bottom Floating "批量做梦" Nebula Iridescent Main Capsule
                VStack {
                    Spacer(minLength: 0)
                    HStack(spacing: 0) {
                        if reserveLeftCardSpace {
                            Color.clear
                                .frame(width: 332, height: 1)
                                .allowsHitTesting(false)
                        }
                        Spacer(minLength: 0)
                        DreamResonanceCapsule(
                            pendingCount: model.dashboard?.pending ?? 0,
                            hasQueuedBatch: model.dashboard?.queuedThrough != nil,
                            isCopiedConfirmation: ui.dreamCopiedConfirmation,
                            isAnimationsPaused: isAnimationsPaused || !showDreamCapsule
                        ) {
                            handleBatchDreamTap()
                        }
                        .fixedSize()
                        Spacer(minLength: 0)
                    }
                    .padding(.bottom, 26)
                    .padding(.horizontal, 18)
                    .opacity(showDreamCapsule ? 1 : 0)
                    .allowsHitTesting(showDreamCapsule)
                    .animation(.easeInOut(duration: 0.20), value: showDreamCapsule)
                    .animation(.spring(response: 0.30, dampingFraction: 0.82), value: reserveLeftCardSpace)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .sheet(isPresented: $ui.showAddAgentHint) {
            addAgentPlaceholderSheet
        }
        .sheet(isPresented: $ui.showDuplicateComparison) {
            DuplicatePairComparisonSheet(
                model: model,
                onInspectMemory: { memoryID in
                    ui.showDuplicateComparison = false
                    onInspectMemoryID(memoryID)
                },
                onClose: {
                    ui.showDuplicateComparison = false
                }
            )
            .applyTheme(model.themeMode)
        }
        .alert("归档全部沉睡记忆？", isPresented: $ui.confirmDormantArchive) {
            Button("取消", role: .cancel) {}
            Button("归档") { model.archiveDormantMemories() }
        } message: {
            Text("将归档本次诊断列出的 \(model.healthSummary.dormantMemoryIDs.count) 条沉睡记忆，可在「已归档」中恢复。")
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
            dreamReviewNotice

            VStack(alignment: .leading, spacing: 10) {
                memoryHubCard
                connectedAgentsCard
                memoryHealthCard
            }

        }
    }

    @ViewBuilder
    private var dreamReviewNotice: some View {
        let decisions = model.dashboard?.decisions ?? []
        let reviewCount = decisions.count { $0.status == "review" }
        let conflictCount = decisions.count { $0.status == "conflict" }

        if reviewCount > 0 || conflictCount > 0 {
            HStack(spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(theme.warning)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    if reviewCount > 0 { Text("\(reviewCount) 条待确认提案") }
                    if conflictCount > 0 { Text("\(conflictCount) 条冲突待处理") }
                }
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(theme.textPrimary)

                Spacer(minLength: 4)

                Button("立即处理", action: onOpenDreamProposals)
                    .buttonStyle(SoftActionButtonStyle(tint: theme.warning, compact: true))
            }
            .padding(11)
            .background(theme.warningSoft, in: RoundedRectangle(cornerRadius: 13))
            .liquidGlassSurface(cornerRadius: 13)
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
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, 6.5)
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
                } else {
                    HStack(spacing: 6) {
                        Text("活跃 \(activeCount)")
                            .foregroundStyle(theme.textPrimary)
                        Text("·")
                            .foregroundStyle(theme.textTertiary)
                        Text("待审 \(pendingCount + reviewCount)")
                            .foregroundStyle((pendingCount + reviewCount) > 0 ? theme.warning : theme.textSecondary)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        hubStatTile(title: "今日召回", value: "\(model.todayRecallCount)", tint: theme.accent, action: onOpenRecallActivity)
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
                        hubQuickPill(label: "待确认", count: reviewCount, tint: reviewCount > 0 ? theme.warning : theme.success, action: onOpenDreamProposals)
                    }

                    HStack(spacing: 6) {
                        Circle()
                            .fill(model.runtimeHealth.embedding.presentation.kind.color(in: theme))
                            .frame(width: 6.5, height: 6.5)
                        Text(model.runtimeHealth.embedding.presentation.detail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Button {
                            onOpenGalaxy()
                        } label: {
                            HStack(spacing: 3) {
                                Text("全屏星图")
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .transition(Self.cardExpandTransition)
            }
        }
        .padding(isExpanded ? 14 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                    .font(.system(size: 11.5, weight: .medium))
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
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                Text("\(count)")
                    .font(.system(size: 11.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
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
                                .font(.system(size: 12, weight: .semibold))
                            Text("接入更多 Agent")
                                .font(.system(size: 12.5, weight: .medium))
                            Spacer()
                            Text("Claude Code · Cursor")
                                .font(.system(size: 11.5))
                                .foregroundStyle(theme.textTertiary)
                        }
                        .foregroundStyle(theme.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
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
                .transition(Self.cardExpandTransition)
            }
        }
        .padding(isExpanded ? 14 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                .font(.system(size: 11.5, weight: .medium))
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
                                .scaleEffect(0.75)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                        Text(isScanning ? "扫描中" : "立即扫描")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(captureEnabled && !isScanning ? theme.textPrimary : theme.textTertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4.5)
                    .background(theme.surfacePrimary.opacity(theme.isDark ? 0.55 : 0.78), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(theme.hairlineBorder, lineWidth: 0.9)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!captureEnabled || isScanning || model.store == nil)
                .help(captureEnabled ? "立即扫描 \(brand.rawValue) 新对话" : "请先在设置中启用 \(brand.rawValue) 采集")

                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 26, height: 26)
                        .background(theme.surfacePrimary.opacity(theme.isDark ? 0.55 : 0.78), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
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
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(ok ? theme.textPrimary : theme.textTertiary)
        }
    }

    // MARK: - Card 3: Memory Health

    private var memoryHealthCard: some View {
        let isExpanded = ui.expandedCard == .health
        let health = model.healthSummary
        let duplicateDeduction = min(Double(health.duplicatePairs.count) * 5, 40)
        let dormantDeduction = min(Double(health.dormantMemoryIDs.count) / Double(max(health.activeCount, 1)) * 40, 35)
        let activeLimit = 250
        let excessCount = max(health.activeCount - activeLimit, 0)
        let scaleDeduction = min(Double(excessCount) / Double(activeLimit) * 25, 25)
        let score = max(0, min(100, 100 - duplicateDeduction - dormantDeduction - scaleDeduction))
        let displayedScore = ((score * 10).rounded(.down) / 10).formatted(.number.precision(.fractionLength(0...1)))
        let needsAttention = score < 100
        let statusColor = needsAttention ? theme.warning : theme.success

        return VStack(alignment: .leading, spacing: isExpanded ? 10 : 0) {
            HStack(spacing: 8) {
                Image(systemName: "heart.text.square")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .frame(width: 24, height: 24)
                    .background(needsAttention ? theme.warningSoft : theme.successSoft, in: RoundedRectangle(cornerRadius: 7))

                Text("记忆健康度")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(theme.textPrimary)

                Spacer(minLength: 4)

                Text("\(displayedScore) 分 · \(needsAttention ? "待整理" : "良好")")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(statusColor)

                if isExpanded {
                    Button { model.refreshHealthSummary() } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("刷新记忆健康体检")
                    .accessibilityLabel("刷新记忆健康体检")
                }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 7) {
                    memoryDistribution(health)
                    if duplicateDeduction > 0 {
                        healthDiagnosis("疑似重复 \(health.duplicatePairs.count) 对", icon: "square.on.square", deduction: duplicateDeduction) {
                            Button("并排对比") {
                                onNonDetailAction()
                                ui.showDuplicateComparison = true
                            }
                            .buttonStyle(SoftActionButtonStyle(compact: true))
                            Button("复制全部合并指令") { model.copyAllDuplicateMergePrompt() }
                                .buttonStyle(SoftActionButtonStyle(tint: theme.accent, compact: true))
                                .help("复制给 Agent，核对全部疑似重复对")
                        }
                    }
                    if dormantDeduction > 0 {
                        healthDiagnosis("沉睡记忆 \(health.dormantMemoryIDs.count) 条", icon: "moon.zzz", deduction: dormantDeduction) {
                            Button("去清理沉睡") { onReviewMemories(.dormant) }
                                .buttonStyle(SoftActionButtonStyle(compact: true))
                            Button("一键归档全部沉睡") {
                                onNonDetailAction()
                                ui.confirmDormantArchive = true
                            }
                            .buttonStyle(SoftActionButtonStyle(tint: theme.warning, compact: true))
                            Button("复制评估指令给 Agent") { model.copyDormantReviewPrompt() }
                                .buttonStyle(SoftActionButtonStyle(tint: theme.accent, compact: true))
                        }
                    }
                    if scaleDeduction > 0 {
                        healthDiagnosis("活跃记忆超过 \(activeLimit) 条", icon: "chart.bar", deduction: scaleDeduction) {
                            Button("按低频 / 最久未用整理") { onReviewMemories(.leastUsed) }
                                .buttonStyle(SoftActionButtonStyle(compact: true))
                        }
                    }
                }
                .transition(Self.cardExpandTransition)
            }
        }
        .padding(isExpanded ? 14 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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

    private func memoryDistribution(_ health: MemoryHealthSummary) -> some View {
        let total = health.activeCount + health.archivedCount
        let activeRatio = total > 0 ? Double(health.activeCount) / Double(total) : 0
        return VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.surfaceSecondary)
                    Capsule()
                        .fill(theme.accent)
                        .frame(width: proxy.size.width * activeRatio)
                }
            }
            .frame(height: 7)

            HStack(spacing: 8) {
                Text("活跃 \(health.activeCount)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(theme.textPrimary)
                Spacer(minLength: 4)
                Button(action: onOpenArchivedMemories) {
                    Label("归档 \(health.archivedCount)", systemImage: "archivebox")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .liquidGlassCapsule()
                .help("查看已归档记忆")
            }
            .monospacedDigit()
        }
    }

    private func healthDiagnosis<Actions: View>(
        _ title: String,
        icon: String,
        deduction: Double,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        let deductionText = deduction < 0.1
            ? "扣分 < 0.1"
            : "−\(deduction.formatted(.number.precision(.fractionLength(0...1)))) 分"
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Label(title, systemImage: icon)
                    .foregroundStyle(theme.textPrimary)
                Spacer(minLength: 4)
                Text(deductionText)
                    .foregroundStyle(theme.warning)
            }
            .font(.caption.weight(.semibold))
            .monospacedDigit()

            FlowLayout(spacing: 5, lineSpacing: 4) { actions() }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .surfaceCard(cornerRadius: 9, padding: 7)
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

@MainActor
private final class DreamFlowPhaseState: ObservableObject {
    var phaseDegrees: Double = 0
    var lastDate: Date?
    var currentSpeed: Double = 52.0

    func advance(to now: Date, isHovered: Bool) -> Double {
        let dt = lastDate.map { min(max(now.timeIntervalSince($0), 0), 1.0 / 20.0) } ?? (1.0 / 60.0)
        lastDate = now
        let targetSpeed: Double = isHovered ? 150.0 : 52.0
        currentSpeed += (targetSpeed - currentSpeed) * min(dt * 7.5, 1.0)
        phaseDegrees = (phaseDegrees + currentSpeed * dt).truncatingRemainder(dividingBy: 360.0)
        return phaseDegrees
    }
}

private struct DreamResonanceCapsule: View {
    @Environment(\.theme) private var theme
    let pendingCount: Int
    let hasQueuedBatch: Bool
    let isCopiedConfirmation: Bool
    let isAnimationsPaused: Bool
    let action: () -> Void

    @StateObject private var hovered = LocalState(false)
    @StateObject private var flowPhase = DreamFlowPhaseState()

    private var subtitleText: String {
        if pendingCount > 0 {
            return "待整理 \(pendingCount) 条新线索 · 点击复制"
        }
        if hasQueuedBatch {
            return "有待整理对话 · 点击复制"
        }
        return "复制指令 · 整理记忆"
    }

    private func flowGradient(angle: Angle) -> AngularGradient {
        let stops: [Gradient.Stop]
        if isCopiedConfirmation {
            stops = [
                .init(color: Color.clear, location: 0.00),
                .init(color: theme.success.opacity(0.35), location: 0.14),
                .init(color: theme.success, location: 0.30),
                .init(color: Color.white, location: 0.45),
                .init(color: theme.accent, location: 0.60),
                .init(color: Color.clear, location: 0.78),
                .init(color: Color.clear, location: 1.00)
            ]
        } else {
            let iceBlue = Color(red: 0.32, green: 0.86, blue: 1.0)
            let indigoViolet = Color(red: 0.58, green: 0.40, blue: 1.0)
            stops = [
                .init(color: Color.clear, location: 0.00),
                .init(color: Color.clear, location: 0.10),
                .init(color: theme.accent, location: 0.26),
                .init(color: iceBlue, location: 0.40),
                .init(color: Color.white, location: 0.49),
                .init(color: indigoViolet, location: 0.60),
                .init(color: theme.agentAntigravity.opacity(0.45), location: 0.70),
                .init(color: Color.clear, location: 0.80),
                .init(color: Color.clear, location: 1.00)
            ]
        }
        return AngularGradient(gradient: Gradient(stops: stops), center: .center, angle: angle)
    }

    var body: some View {
        let isHovered = hovered.value
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: isAnimationsPaused)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let angle = Angle.degrees(flowPhase.advance(to: timeline.date, isHovered: isHovered))
            let breathe = 0.90 + 0.10 * sin(t * 2.4)
            let flowing = flowGradient(angle: angle)

            Button(action: action) {
                HStack(spacing: 14) {
                    // Breathing 42x42 crescent + sparkle orb (19pt icon)
                    ZStack {
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [
                                        (isCopiedConfirmation ? theme.success : theme.accent).opacity(theme.isDark ? 0.42 : 0.28),
                                        (isCopiedConfirmation ? theme.accent : theme.agentAntigravity).opacity(theme.isDark ? 0.18 : 0.10),
                                        Color.clear
                                    ],
                                    center: .center,
                                    startRadius: 2,
                                    endRadius: 22
                                )
                            )
                            .frame(width: 42, height: 42)
                            .scaleEffect(breathe)

                        Image(systemName: isCopiedConfirmation ? "checkmark.circle.fill" : "moon.stars.fill")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(
                                isCopiedConfirmation
                                    ? AnyShapeStyle(theme.success)
                                    : AnyShapeStyle(
                                        LinearGradient(
                                            colors: [theme.accent, Color(red: 0.38, green: 0.86, blue: 1.0), theme.agentAntigravity],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                            )
                    }
                    .frame(width: 42, height: 42)

                    if isCopiedConfirmation {
                        Text("✓ 做梦指令已复制 · 粘贴到 Agent 继续")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    } else {
                        VStack(alignment: .leading, spacing: 2.5) {
                            HStack(spacing: 7) {
                                Text("批量做梦")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(theme.textPrimary)
                                if pendingCount > 0 {
                                    Text("\(pendingCount)")
                                        .font(.system(size: 12, weight: .bold))
                                        .monospacedDigit()
                                        .foregroundStyle(theme.accent)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(theme.accentSoft, in: Capsule())
                                }
                            }
                            Text(subtitleText)
                                .font(.system(size: 12, weight: .regular))
                                .foregroundStyle(theme.textSecondary)
                                .lineLimit(1)
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))

                        HStack(spacing: 5) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 12, weight: .semibold))
                            Text("复制")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(theme.accentSoft, in: Capsule())
                        .overlay(Capsule().stroke(theme.accentBorder, lineWidth: 0.9))
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 13)
                .background {
                    ZStack {
                        // Layer 1: Outer diffused nebula glow (same-phase rotating AngularGradient)
                        Capsule()
                            .stroke(flowing, lineWidth: isHovered ? 6.0 : 3.8)
                            .blur(radius: isHovered ? 14 : 9)
                            .opacity(isHovered ? 0.95 : 0.72)

                        // Liquid Glass capsule body
                        LiquidGlassFill(shape: Capsule())
                    }
                }
                .overlay {
                    ZStack {
                        // Subtle top white specular inner rim
                        Capsule()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(theme.isDark ? 0.28 : 0.78),
                                        Color.white.opacity(theme.isDark ? 0.06 : 0.20),
                                        Color.clear
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 1.0
                            )

                        // Layer 2: Inner crisp flowing edge (same-phase rotating AngularGradient)
                        Capsule()
                            .strokeBorder(flowing, lineWidth: isHovered ? 2.4 : 1.8)
                    }
                }
                .shadow(
                    color: (isCopiedConfirmation ? theme.success : theme.accent).opacity(theme.isDark ? (isHovered ? 0.42 : 0.24) : (isHovered ? 0.28 : 0.16)),
                    radius: isHovered ? 24 : 15,
                    y: isHovered ? 9 : 6
                )
                .shadow(color: theme.glassShadow, radius: 12, y: 5)
            }
            .buttonStyle(.plain)
            .scaleEffect(isHovered ? 1.05 : 1.0)
            .offset(y: isHovered ? -3 : 0)
            .animation(.spring(response: 0.32, dampingFraction: 0.68), value: isHovered)
            .onHover { hovered.value = $0 }
            .help("复制批量做梦指令到剪贴板，粘贴到 Agent 中整理近期对话为长期记忆")
        }
        .onChange(of: isAnimationsPaused) { _, paused in
            if !paused {
                flowPhase.lastDate = nil
            }
        }
    }
}

// MARK: - Duplicate Pair Comparison Sheet

private struct DuplicatePairComparisonSheet: View {
    @Environment(\.theme) private var theme
    @ObservedObject var model: AppModel
    let onInspectMemory: (String) -> Void
    let onClose: () -> Void
    @StateObject private var selectedIndex = LocalState(0)

    private var pairs: [MemoryHealthSummary.DuplicatePair] { model.healthSummary.duplicatePairs }

    private var pair: DuplicateComparisonItem? {
        guard pairs.indices.contains(selectedIndex.value) else { return nil }
        let entry = pairs[selectedIndex.value]
        guard let memoryA = try? model.memory(id: entry.memoryAID), !memoryA.archived,
              let memoryB = try? model.memory(id: entry.memoryBID), !memoryB.archived else { return nil }
        return DuplicateComparisonItem(memoryA: memoryA, memoryB: memoryB, similarity: entry.similarity)
    }

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
                    Text("两条记忆语义高度接近，可直接保留其一并归档另一条，或复制合并指令交由 Agent 智能融合。")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer()
                if pairs.count > 1 { pairNavigation }
            }

            if let pair {
                comparisonContent(pair)
            } else {
                EmptyStateCard(
                    icon: "square.on.square",
                    title: "该重复对已变更",
                    description: "可切换其他重复对，或关闭对比后刷新健康度。"
                )
                .frame(maxHeight: .infinity)
                Button("关闭", action: onClose)
                    .buttonStyle(SoftActionButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 760, height: 450)
        .background(theme.canvasBackground)
        .onChange(of: pairs.count) { _, count in
            selectedIndex.value = min(selectedIndex.value, max(0, count - 1))
        }
    }

    private var pairNavigation: some View {
        HStack(spacing: 8) {
            Button { selectedIndex.value -= 1 } label: {
                Label("上一对", systemImage: "chevron.left").labelStyle(.iconOnly)
            }
            .buttonStyle(SoftActionButtonStyle(compact: true))
            .disabled(selectedIndex.value == 0)
            Text("\(selectedIndex.value + 1) / \(pairs.count)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(theme.textSecondary)
            Button { selectedIndex.value += 1 } label: {
                Label("下一对", systemImage: "chevron.right").labelStyle(.iconOnly)
            }
            .buttonStyle(SoftActionButtonStyle(compact: true))
            .disabled(selectedIndex.value + 1 >= pairs.count)
        }
    }

    @ViewBuilder
    private func comparisonContent(_ pair: DuplicateComparisonItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            memoryPane(
                pair.memoryA,
                label: "记忆 A",
                keepActionTitle: "保留 A，归档 B",
                archiveOther: {
                    model.archiveMemory(id: pair.memoryB.id, archived: true)
                    onClose()
                }
            )
            memoryPane(
                pair.memoryB,
                label: "记忆 B",
                keepActionTitle: "保留 B，归档 A",
                archiveOther: {
                    model.archiveMemory(id: pair.memoryA.id, archived: true)
                    onClose()
                }
            )
        }

        HStack {
            Button {
                model.copyMergeDuplicatePrompt(memoryA: pair.memoryA, memoryB: pair.memoryB)
            } label: {
                Label("复制合并指令", systemImage: "sparkles")
            }
            .buttonStyle(SoftActionButtonStyle(tint: theme.accent))
            .help("复制包含两条记忆完整内容的合并指令，粘贴到 Agent 中智能融合")

            ScorePill(
                label: "向量相似度",
                value: "\(Int((pair.similarity * 100).rounded()))%",
                tint: theme.warning
            )
            Spacer()

            Button("关闭", action: onClose)
                .buttonStyle(SoftActionButtonStyle())
                .keyboardShortcut(.cancelAction)
        }
    }

    private func memoryPane(
        _ memory: Memory,
        label: String,
        keepActionTitle: String,
        archiveOther: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            FlowLayout(spacing: 6, lineSpacing: 6) {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .padding(.vertical, 3)
                ScopeTag(projectPath: memory.project)
                ScorePill(label: "v", value: "\(memory.version)")
                ScorePill(label: "命中", value: "\(memory.hitCount) 次", tint: memory.hitCount > 0 ? theme.warning : theme.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(memory.title)
                .font(.headline)
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            Text("更新于 " + Date(timeIntervalSince1970: memory.updated).formatted(.dateTime.year().month().day().hour().minute()))
                .font(.system(size: 11.5))
                .monospacedDigit()
                .foregroundStyle(theme.textTertiary)

            ScrollView {
                Text(memory.body)
                    .font(.callout)
                    .foregroundStyle(theme.textPrimary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                Button(action: archiveOther) {
                    Label(keepActionTitle, systemImage: "archivebox")
                }
                .buttonStyle(SoftActionButtonStyle(tint: theme.warning, compact: true))
                .help("\(keepActionTitle)，归档后可随时在记忆详情中恢复")

                Spacer(minLength: 4)

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
