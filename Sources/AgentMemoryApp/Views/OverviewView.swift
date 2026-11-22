import AgentMemoryCore
import SwiftUI

private struct RecentRecalledMemoryItem: Identifiable {
    let id: String
    let memoryID: String
    let title: String
    let excerpt: String
    let agent: AgentBrand?
    let timestamp: Date
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
    @Published var showAddAgentHint = false
    @Published var comparingDuplicate: DuplicateComparisonItem?
}

struct OverviewView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var model: AppModel
    @Binding var selection: AppPage
    let onSearchMemory: (String) -> Void
    let onInspectMemoryID: (String) -> Void
    let onOpenAgentSettings: (AgentBrand) -> Void
    let onInspectDormantMemories: () -> Void
    let onNonDetailAction: () -> Void

    @StateObject private var ui = OverviewUIState()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerRow
                topQuickActionBar
                connectedAgentsRow
                todayRecallWideCard
                kpiRow
                memoryHealthSection
                galaxyPreviewContainer
            }
            .padding(24)
        }
        .background(theme.canvasBackground)
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

    // MARK: - Header

    private var headerRow: some View {
        let embedding = vectorCapsulePresentation
        let runtime = model.overallRuntimeStatus
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("记忆中枢概览")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Text("跨 Agent 持久记忆、实时状态监控与语义检索")
                    .font(.callout)
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer()
            HStack(spacing: 8) {
                StatusCapsule(title: embedding.title, kind: embedding.kind, showSpinner: embedding.spinning)
                    .help("\(model.runtimeHealth.embedding.presentation.detail) · \(model.smartCapture ? "省电模式（FSEvents 监听，空闲自动休眠）" : "定时轮询模式（30s）")")
                StatusCapsule(title: runtime.title, kind: runtime.kind, showSpinner: runtime.spinning)
                    .help(model.smartCapture ? "省电模式已开启：通过 macOS FSEvents 按需采集" : "当前为定时轮询采集模式")
            }
        }
    }

    private var vectorCapsulePresentation: (title: String, kind: RuntimeStatusKind, spinning: Bool) {
        switch model.runtimeHealth.embedding {
        case .checking:
            return ("向量检查中", .indexing, true)
        case .indexing:
            return ("向量索引中", .indexing, true)
        case .ready:
            return ("本地向量已就绪", .active, false)
        case .unavailable:
            return ("向量未就绪", .paused, false)
        case .failed:
            return ("向量异常", .error, false)
        }
    }

    // MARK: - Top High-Frequency Bar

    private var topQuickActionBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(theme.textTertiary)
                TextField("搜索记忆标题、正文或技术词，回车直达检索透视…", text: $ui.searchDraft)
                    .textFieldStyle(.plain)
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
                }
                Button {
                    submitOverviewSearch()
                } label: {
                    Text("检索")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(theme.accentSoft, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(theme.surfacePrimary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(theme.hairlineBorder, lineWidth: 1)
            )
            .shadow(color: theme.cardShadow, radius: 3, y: 1)

            Button {
                model.copyBatchDream()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "moon.stars.fill")
                    Text("复制批量做梦指令")
                    if let pending = model.dashboard?.pending, pending > 0 {
                        Text("\(pending)")
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.white.opacity(0.22), in: Capsule())
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.dashboard?.queuedThrough == nil)
            .help(model.dashboard?.queuedThrough == nil ? "当前暂无待做梦记录" : "复制批量做梦指令到剪贴板，粘贴到 Agent 中处理待做梦记录")
        }
    }

    private func submitOverviewSearch() {
        let query = ui.searchDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        onSearchMemory(query)
        ui.searchDraft = ""
    }

    // MARK: - Row 1: Connected Agents (Extensible Equal-Height Grid + Add Card)

    private var connectedAgentsRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("已接入 Agent", count: 2)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 250), spacing: 12)],
                alignment: .leading,
                spacing: 12
            ) {
                agentHealthCard(
                    brand: .codex,
                    connected: model.connection?.toolsAvailable == true,
                    captureEnabled: model.enabled,
                    captureState: model.runtimeHealth.codexCapture,
                    recallActive: model.recallEnabled && model.connection?.recallInstalled == true,
                    lastScan: model.runtimeHealth.codexLastScan,
                    isScanning: model.scanning,
                    onScan: { Task { await model.scan(force: true) } },
                    onOpenSettings: { onOpenAgentSettings(.codex) }
                )
                agentHealthCard(
                    brand: .antigravity,
                    connected: model.antigravityConnection?.toolsAvailable == true,
                    captureEnabled: model.antigravityEnabled,
                    captureState: model.runtimeHealth.antigravityCapture,
                    recallActive: model.antigravityRecallEnabled && model.antigravityConnection?.recallInstalled == true,
                    lastScan: model.runtimeHealth.antigravityLastScan,
                    isScanning: model.antigravityScanning,
                    onScan: { Task { await model.scanAntigravity(force: true) } },
                    onOpenSettings: { onOpenAgentSettings(.antigravity) }
                )
                AddAgentPlaceholderCard {
                    onNonDetailAction()
                    ui.showAddAgentHint = true
                }
            }
        }
    }

    private func agentHealthCard(
        brand: AgentBrand,
        connected: Bool,
        captureEnabled: Bool,
        captureState: RuntimeHealth.CaptureState,
        recallActive: Bool,
        lastScan: Date?,
        isScanning: Bool,
        onScan: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void
    ) -> some View {
        let capture = captureState.presentation(smartCapture: model.smartCapture)
        let isCapturing = captureState == .idle || captureState == .scanning
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                AgentTag(agent: brand, active: connected || isCapturing)
                Spacer()
                StatusCapsule(title: capture.title, kind: capture.kind, showSpinner: capture.spinning)
            }

            HStack(spacing: 12) {
                miniLight("MCP", ok: connected)
                miniLight("采集", ok: isCapturing)
                miniLight("自动注入", ok: recallActive)
            }

            Spacer(minLength: 4)

            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.caption2)
                    if let lastScan {
                        Text(lastScan, format: .dateTime.hour().minute())
                            .monospacedDigit()
                    } else {
                        Text(isCapturing ? "待首次扫描" : "未开启")
                    }
                }
                .font(.caption2)
                .foregroundStyle(theme.textTertiary)
                .lineLimit(1)

                Spacer(minLength: 4)

                Button(action: onScan) {
                    HStack(spacing: 4) {
                        if isScanning {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.75)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        Text(isScanning ? "扫描中" : "立即扫描")
                            .font(.caption2.weight(.medium))
                    }
                    .foregroundStyle(captureEnabled && !isScanning ? theme.textPrimary : theme.textTertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(theme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(theme.hairlineBorder, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!captureEnabled || isScanning || model.store == nil)
                .help(captureEnabled ? "立即扫描 \(brand.rawValue) 新对话" : "请先在设置中启用 \(brand.rawValue) 采集")

                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 24, height: 24)
                        .background(theme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(theme.hairlineBorder, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help("前往设置配置 \(brand.rawValue) 连接与自动检索")
                .accessibilityLabel("\(brand.rawValue) 连接设置")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 112, maxHeight: .infinity, alignment: .topLeading)
        .surfaceCard(cornerRadius: 12, padding: 14)
    }

    private func miniLight(_ label: String, ok: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(ok ? theme.success : theme.textTertiary.opacity(0.45))
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption2)
                .foregroundStyle(ok ? theme.textPrimary : theme.textTertiary)
        }
    }

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
                Button("知道了") {
                    ui.showAddAgentHint = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 400)
        .applyTheme(model.themeMode)
    }

    // MARK: - Row 2: Today Recall Full-Width Card

    private var recentRecalledMemories: [RecentRecalledMemoryItem] {
        let recallEvents = model.recentActivities.filter { $0.kind == .recall && !$0.memoryIDs.isEmpty }
        var seen = Set<String>()
        var items: [RecentRecalledMemoryItem] = []

        for event in recallEvents {
            for memoryID in event.memoryIDs {
                guard !seen.contains(memoryID) else { continue }
                seen.insert(memoryID)

                let resolvedMemory: Memory? = model.hits.first(where: { $0.id == memoryID })?.memory
                    ?? (try? model.memory(id: memoryID))
                let title = resolvedMemory?.title ?? "记忆 \(memoryID.prefix(10))"
                let rawBody = resolvedMemory?.body ?? (event.message ?? "点击在右侧检查器查看完整记忆内容")
                let singleLineExcerpt = rawBody
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                items.append(RecentRecalledMemoryItem(
                    id: "\(event.id)-\(memoryID)",
                    memoryID: memoryID,
                    title: title,
                    excerpt: singleLineExcerpt,
                    agent: event.agent?.brand,
                    timestamp: event.timestamp
                ))
                if items.count >= 3 { return items }
            }
        }
        return items
    }

    private var todayRecallWideCard: some View {
        let recalledItems = recentRecalledMemories
        return HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Label("今日自动注入", systemImage: "bolt.horizontal.circle.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    Text(model.recallCrossProject ? "跨项目" : "当前项目+全局")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(theme.accentSoft, in: Capsule())
                }

                HStack(alignment: .firstTextBaseline, spacing: 24) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.todayRecallCount, format: .number)
                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(theme.textPrimary)
                        Text("注入次数")
                            .font(.caption2)
                            .foregroundStyle(theme.textTertiary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("~\(model.todayRecallEstimatedTokens.formatted(.number))")
                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(theme.accent)
                        Text("估算 Token")
                            .font(.caption2)
                            .foregroundStyle(theme.textTertiary)
                    }
                }

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    Text("已启用同会话去重与短句过滤")
                        .font(.caption2)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        selection = .activity
                    } label: {
                        HStack(spacing: 3) {
                            Text("查看活动")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(theme.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 248, alignment: .topLeading)

            Rectangle()
                .fill(theme.hairlineBorder)
                .frame(width: 1)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("最近自动注入的记忆摘要")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.textSecondary)
                    Spacer()
                    if let latest = recalledItems.first {
                        HStack(spacing: 4) {
                            Text("最近一次")
                            Text(latest.timestamp, format: .dateTime.hour().minute())
                                .monospacedDigit()
                        }
                        .font(.caption2)
                        .foregroundStyle(theme.textTertiary)
                    }
                }

                if recalledItems.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("最近暂无自动注入命中记录")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(theme.textSecondary)
                        Text("开启自动检索后，Codex 或 Antigravity 在对话前自动注入的关键记忆摘要会实时显示在此，点击可直达详情检查器。")
                            .font(.caption)
                            .foregroundStyle(theme.textTertiary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                } else {
                    VStack(spacing: 6) {
                        ForEach(recalledItems) { item in
                            Button {
                                onInspectMemoryID(item.memoryID)
                            } label: {
                                HStack(alignment: .center, spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(item.title)
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(theme.textPrimary)
                                                .lineLimit(1)
                                            if let agent = item.agent {
                                                Text(agent.rawValue)
                                                    .font(.system(size: 10, weight: .medium))
                                                    .foregroundStyle(agent.color(in: theme))
                                                    .padding(.horizontal, 5)
                                                    .padding(.vertical, 1)
                                                    .background(agent.softColor(in: theme), in: Capsule())
                                            }
                                        }
                                        Text(item.excerpt)
                                            .font(.caption2)
                                            .foregroundStyle(theme.textSecondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 6)
                                    Text(item.timestamp, format: .dateTime.hour().minute())
                                        .font(.caption2)
                                        .monospacedDigit()
                                        .foregroundStyle(theme.textTertiary)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(theme.textTertiary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(theme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(theme.hairlineBorder, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                            .help("点击在右侧检查器查看「\(item.title)」")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .surfaceCard(cornerRadius: 13, padding: 15)
    }

    // MARK: - Row 3: KPI Cards (3-Column Equal Height)

    private var kpiRow: some View {
        HStack(alignment: .top, spacing: 12) {
            KPIMetricCard(
                title: "正式记忆",
                value: "\(model.dashboard?.memories ?? 0)",
                subtitle: "已沉淀且可检索的长期记忆",
                icon: "brain.head.profile",
                tint: theme.accent
            ) {
                selection = .memory
            }
            KPIMetricCard(
                title: "待做梦",
                value: "\(model.dashboard?.pending ?? 0)",
                subtitle: "等待归纳提炼的新对话证据",
                icon: "moon.stars",
                tint: theme.info
            ) {
                selection = .dream
            }
            KPIMetricCard(
                title: "待确认",
                value: "\(model.dashboard?.review ?? 0)",
                subtitle: "存在冲突或需人工审阅的提案",
                icon: "checkmark.shield",
                tint: (model.dashboard?.review ?? 0) > 0 ? theme.warning : theme.success
            ) {
                selection = .dream
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Row 4: Memory Health Summary

    private var memoryHealthSection: some View {
        let health = model.healthSummary
        let total = max(health.activeCount + health.archivedCount, 0)
        let activeRatio = total > 0 ? Double(health.activeCount) / Double(total) : 1.0

        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader("记忆健康度") {
                Button {
                    model.refreshHealthSummary()
                } label: {
                    Label("刷新体检", systemImage: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                }
                .buttonStyle(.plain)
            }

            HStack(alignment: .top, spacing: 12) {
                // 1. Active vs Archived Distribution
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("活跃 / 归档分布", systemImage: "chart.bar.xaxis")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(theme.textPrimary)
                        Spacer()
                        Text("总计 \(total)")
                            .font(.caption2.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(theme.textTertiary)
                    }

                    GeometryReader { proxy in
                        let width = max(proxy.size.width, 1)
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(theme.surfaceSecondary)
                            Capsule()
                                .fill(theme.accent)
                                .frame(width: total > 0 ? max(width * activeRatio, health.activeCount > 0 ? 6 : 0) : 0)
                        }
                    }
                    .frame(height: 8)

                    HStack(spacing: 14) {
                        HStack(spacing: 5) {
                            Circle().fill(theme.accent).frame(width: 7, height: 7)
                            Text("活跃 \(health.activeCount)")
                                .font(.caption.weight(.medium))
                                .monospacedDigit()
                                .foregroundStyle(theme.textPrimary)
                        }
                        HStack(spacing: 5) {
                            Circle().fill(theme.textTertiary.opacity(0.45)).frame(width: 7, height: 7)
                            Text("归档 \(health.archivedCount)")
                                .font(.caption.weight(.medium))
                                .monospacedDigit()
                                .foregroundStyle(theme.textSecondary)
                        }
                        Spacer()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .surfaceCard(cornerRadius: 12, padding: 13)

                // 2. Dormant Memories (>30 days untouched & 0 hits)
                Button {
                    if !health.dormantMemoryIDs.isEmpty {
                        onInspectDormantMemories()
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("沉睡记忆", systemImage: "moon.zzz")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(theme.textPrimary)
                            Spacer()
                            if !health.dormantMemoryIDs.isEmpty {
                                HStack(spacing: 3) {
                                    Text("去筛选")
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 9, weight: .semibold))
                                }
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(theme.accent)
                            }
                        }

                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(health.dormantMemoryIDs.count)")
                                .font(.system(size: 24, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(health.dormantMemoryIDs.isEmpty ? theme.success : theme.warning)
                            Text("条")
                                .font(.caption)
                                .foregroundStyle(theme.textSecondary)
                        }

                        Text("> 30 天未更新且零命中，适合定期复审或归档")
                            .font(.caption2)
                            .foregroundStyle(theme.textTertiary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .surfaceCard(cornerRadius: 12, padding: 13)
                }
                .buttonStyle(.plain)
                .disabled(health.dormantMemoryIDs.isEmpty)
            }
            .fixedSize(horizontal: false, vertical: true)

            // 3. Suspected Duplicate Pairs
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("疑似重复记忆对", systemImage: "square.on.square")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(theme.textPrimary)
                    Text("\(health.duplicatePairs.count)")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(health.duplicatePairs.isEmpty ? theme.success : theme.warning)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(health.duplicatePairs.isEmpty ? theme.successSoft : theme.warningSoft, in: Capsule())
                    Spacer()
                    if !health.duplicatePairs.isEmpty {
                        Text("点击任意一对展开并排对比")
                            .font(.caption2)
                            .foregroundStyle(theme.textTertiary)
                    }
                }

                if health.duplicatePairs.isEmpty {
                    Text("当前活跃记忆语义分布良好，未检测到高相似度重复记忆对。")
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                } else {
                    VStack(spacing: 6) {
                        ForEach(Array(health.duplicatePairs.prefix(5).enumerated()), id: \.offset) { _, pair in
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
                                HStack(spacing: 10) {
                                    ScorePill(
                                        label: "相似度",
                                        value: "\(Int((pair.similarity * 100).rounded()))%",
                                        tint: theme.warning
                                    )
                                    Text(memA?.title ?? String(pair.memoryAID.prefix(10)))
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(theme.textPrimary)
                                        .lineLimit(1)
                                    Image(systemName: "arrow.left.arrow.right")
                                        .font(.caption2)
                                        .foregroundStyle(theme.textTertiary)
                                    Text(memB?.title ?? String(pair.memoryBID.prefix(10)))
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(theme.textPrimary)
                                        .lineLimit(1)
                                    Spacer()
                                    Text("对比")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(theme.accent)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(theme.textTertiary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(theme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(theme.hairlineBorder, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(memA == nil || memB == nil)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .surfaceCard(cornerRadius: 12, padding: 13)
        }
    }

    private func resolveMemory(id: String) -> Memory? {
        if let hit = model.hits.first(where: { $0.id == id }) {
            return hit.memory
        }
        return try? model.memory(id: id, version: nil)
    }

    // MARK: - Wave 3 Semantic Galaxy Placeholder

    private var galaxyPreviewContainer: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("语义记忆星图") {
                ScorePill(label: "Wave 3", value: "即将上线", tint: theme.accent)
            }
            ZStack {
                GalaxyConstellationPreview(theme: theme, memoryCount: model.dashboard?.memories ?? 0)
                    .frame(height: 170)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(spacing: 6) {
                    Text("Memory Galaxy · 语义关联画布")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(theme.textPrimary)
                    Text("将基于纯原生 SwiftUI Canvas 渲染活跃节点、命中热度、向量相似连线与重复簇提示。")
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(theme.hairlineBorder, lineWidth: 1)
                )
            }
        }
        .surfaceCard(cornerRadius: 14, padding: 14)
    }
}

// MARK: - Permanent "+" Extension Card

private struct AddAgentPlaceholderCard: View {
    @Environment(\.theme) private var theme
    let action: () -> Void

    @StateObject private var hovered = LocalState(false)

    var body: some View {
        let isHovered = hovered.value
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(isHovered ? theme.accent : theme.textSecondary)
                    .frame(width: 34, height: 34)
                    .background(isHovered ? theme.accentSoft : theme.surfaceSecondary, in: Circle())
                Text("接入更多 Agent")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(isHovered ? theme.textPrimary : theme.textSecondary)
                Text("更多 Agent 适配开发中")
                    .font(.caption2)
                    .foregroundStyle(theme.textTertiary)
            }
            .frame(maxWidth: .infinity, minHeight: 112, maxHeight: .infinity)
            .padding(14)
            .background(
                (isHovered ? theme.surfaceElevated : theme.surfaceSecondary.opacity(0.65)),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        isHovered ? theme.accentBorder : theme.strongBorder,
                        style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered.value = $0 }
        .help("查看已支持的 Agent 与后续扩展计划")
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
                        .font(.caption)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .surfaceCard(cornerRadius: 11, padding: 13)
    }
}

// MARK: - Galaxy Preview Canvas

private struct GalaxyConstellationPreview: View {
    let theme: ThemePalette
    let memoryCount: Int

    private let sampleNodes: [(x: CGFloat, y: CGFloat, r: CGFloat, isGlobal: Bool)] = [
        (0.14, 0.34, 5.5, false),
        (0.24, 0.68, 4.5, true),
        (0.36, 0.28, 7.0, false),
        (0.47, 0.62, 5.0, false),
        (0.58, 0.36, 8.0, true),
        (0.71, 0.66, 6.0, false),
        (0.83, 0.30, 5.0, true),
        (0.88, 0.64, 4.0, false)
    ]

    private let sampleEdges: [(Int, Int)] = [
        (0, 1), (0, 2), (1, 3), (2, 3), (2, 4), (3, 4), (4, 5), (4, 6), (5, 7), (6, 7)
    ]

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(theme.galaxyBackground))

            let step: CGFloat = 24
            var x: CGFloat = step / 2
            while x < size.width {
                var y: CGFloat = step / 2
                while y < size.height {
                    let dot = CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5)
                    context.fill(Path(ellipseIn: dot), with: .color(theme.galaxyGrid))
                    y += step
                }
                x += step
            }

            let points = sampleNodes.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }

            for (from, to) in sampleEdges {
                var path = Path()
                path.move(to: points[from])
                path.addLine(to: points[to])
                context.stroke(path, with: .color(theme.galaxyEdge), lineWidth: 1)
            }

            for (index, node) in sampleNodes.enumerated() {
                let p = points[index]
                let color = node.isGlobal ? theme.scopeGlobal : theme.scopeProject
                let glowRect = CGRect(x: p.x - node.r * 2.2, y: p.y - node.r * 2.2, width: node.r * 4.4, height: node.r * 4.4)
                context.fill(Path(ellipseIn: glowRect), with: .color(color.opacity(theme.isDark ? 0.22 : 0.16)))
                let coreRect = CGRect(x: p.x - node.r, y: p.y - node.r, width: node.r * 2, height: node.r * 2)
                context.fill(Path(ellipseIn: coreRect), with: .color(color))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(theme.hairlineBorder, lineWidth: 1)
        )
    }
}
