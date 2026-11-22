import AgentMemoryCore
import SwiftUI

enum ActivityEventFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case recall = "自动注入"
    case scan = "采集"
    case search = "检索"
    case dream = "做梦"
    case error = "异常"

    var id: Self { self }

    func matches(_ kind: ActivityEvent.Kind) -> Bool {
        switch self {
        case .all: return true
        case .recall: return kind == .recall
        case .scan: return kind == .scan
        case .search: return kind == .search
        case .dream: return kind == .dreamClaim || kind == .dreamSubmit || kind == .dreamRollback
        case .error: return kind == .error
        }
    }
}

enum ActivityAgentFilter: String, CaseIterable, Identifiable {
    case all = "全部 Agent"
    case codex = "Codex"
    case antigravity = "Antigravity"

    var id: Self { self }

    func matches(_ agent: ActivityEvent.Agent?) -> Bool {
        switch self {
        case .all: return true
        case .codex: return agent == .codex
        case .antigravity: return agent == .antigravity
        }
    }
}

struct ActivityView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var model: AppModel
    let onInspectMemoryID: (String) -> Void

    @StateObject private var kindFilter = LocalState(ActivityEventFilter.all)
    @StateObject private var agentFilter = LocalState(ActivityAgentFilter.all)

    private var filteredEvents: [ActivityEvent] {
        model.recentActivities.filter { event in
            kindFilter.value.matches(event.kind) && agentFilter.value.matches(event.agent)
        }
    }

    private var memoryTitleLookup: [String: String] {
        Dictionary(uniqueKeysWithValues: model.hits.map { ($0.id, $0.memory.title) })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerRow
                livePulseBar
                sourceHealthRow
                timelineSection
            }
            .padding(24)
        }
        .background(Color.clear)
    }

    // MARK: - Cross-Agent Real-Time Hit Pulse Bar

    @ViewBuilder
    private var livePulseBar: some View {
        if let pulseAt = model.lastPulseAt, !model.lastPulseMemoryIDs.isEmpty {
            let agentBrand = model.lastPulseAgent?.brand
            let accent = agentBrand?.color(in: theme) ?? theme.accent
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(accent.opacity(theme.isDark ? 0.25 : 0.18))
                            .frame(width: 18, height: 18)
                        Circle()
                            .fill(accent)
                            .frame(width: 8, height: 8)
                            .shadow(color: accent.opacity(0.65), radius: 3)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text("实时命中脉搏")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(theme.textPrimary)
                            if let agentBrand {
                                AgentTag(agent: agentBrand)
                            }
                            Text("命中 \(model.lastPulseMemoryIDs.count) 条记忆")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(theme.textSecondary)
                        }
                        Text("最近一次触发于 \(pulseAt.formatted(.dateTime.hour().minute().second()))")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(theme.textTertiary)
                    }
                }

                Spacer(minLength: 8)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.lastPulseMemoryIDs.prefix(4), id: \.self) { memoryID in
                            let title = memoryTitleLookup[memoryID]
                                ?? (try? model.memory(id: memoryID, version: nil))?.title
                                ?? String(memoryID.prefix(10))
                            Button {
                                onInspectMemoryID(memoryID)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "bolt.fill")
                                        .font(.system(size: 9, weight: .semibold))
                                    Text(title)
                                        .font(.caption2.weight(.medium))
                                        .lineLimit(1)
                                }
                                .foregroundStyle(accent)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(accent.opacity(theme.isDark ? 0.15 : 0.10), in: Capsule())
                                .overlay(Capsule().stroke(accent.opacity(0.32), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .help("点击查看命中记忆「\(title)」")
                        }
                    }
                }
                .frame(maxWidth: 360, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(theme.surfacePrimary, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(accent.opacity(0.32), lineWidth: 1)
            )
            .shadow(color: theme.cardShadow, radius: 4, y: 2)
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("运行活动与脉搏")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(theme.textPrimary)
                Text("实时追踪采集扫描、自动注入（含命中条数与估算 Token）、主动检索与做梦变更")
                    .font(.callout)
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer()
            HStack(spacing: 8) {
                ScorePill(
                    label: "今日注入",
                    value: "\(model.todayRecallCount) 次",
                    tint: theme.success
                )
                ScorePill(
                    label: "估算 Token",
                    value: "~\(model.todayRecallEstimatedTokens.formatted(.number))",
                    tint: theme.accent
                )
                Button {
                    Task { await model.scanAllEnabled(force: true) }
                } label: {
                    Label(model.isAnyScanning ? "扫描中…" : "立即扫描", systemImage: "arrow.clockwise")
                }
                .buttonStyle(SoftActionButtonStyle(compact: true))
                .disabled(!model.isAnySourceEnabled || model.isAnyScanning)
            }
        }
    }

    // MARK: - Source Health Cards

    private var sourceHealthRow: some View {
        HStack(spacing: 12) {
            sourceStatusCard(
                brand: .codex,
                enabled: model.enabled,
                captureState: model.runtimeHealth.codexCapture,
                lastScan: model.runtimeHealth.codexLastScan,
                statusText: model.status,
                onToggle: { model.capture(!model.enabled) },
                onScan: { Task { await model.scan(force: true) } }
            )
            sourceStatusCard(
                brand: .antigravity,
                enabled: model.antigravityEnabled,
                captureState: model.runtimeHealth.antigravityCapture,
                lastScan: model.runtimeHealth.antigravityLastScan,
                statusText: model.antigravityStatus,
                onToggle: { model.captureAntigravity(!model.antigravityEnabled) },
                onScan: { Task { await model.scanAntigravity(force: true) } }
            )
        }
    }

    private func sourceStatusCard(
        brand: AgentBrand,
        enabled: Bool,
        captureState: RuntimeHealth.CaptureState,
        lastScan: Date?,
        statusText: String,
        onToggle: @escaping () -> Void,
        onScan: @escaping () -> Void
    ) -> some View {
        let capture = captureState.presentation(smartCapture: model.smartCapture)
        let isScanning = captureState == .scanning
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                AgentTag(agent: brand, active: enabled)
                Spacer()
                StatusCapsule(title: capture.title, kind: capture.kind, showSpinner: capture.spinning)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("最近扫描")
                        .font(.caption)
                        .foregroundStyle(theme.textTertiary)
                    if let lastScan {
                        Text(lastScan, format: .dateTime.month().day().hour().minute())
                            .font(.caption.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(theme.textPrimary)
                    } else {
                        Text("尚未扫描")
                            .font(.caption)
                            .foregroundStyle(theme.textTertiary)
                    }
                }
                Text(statusText.isEmpty ? (enabled ? "等待新对话触发增量采集" : "开启后将从当前时间起增量采集") : statusText)
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                Button(enabled ? "暂停采集" : "启用采集", action: onToggle)
                    .buttonStyle(SoftActionButtonStyle(compact: true))
                    .disabled(model.store == nil)
                Button("立即扫描", action: onScan)
                    .buttonStyle(SoftActionButtonStyle(tint: theme.accent, compact: true))
                    .disabled(!enabled || isScanning || model.store == nil)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(cornerRadius: 13, padding: 14)
    }

    // MARK: - Activity Timeline

    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                SectionHeader("活动日志", count: filteredEvents.count)
                Picker("Agent", selection: $agentFilter.value) {
                    ForEach(ActivityAgentFilter.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 124)

                SegmentedPillBar(
                    options: ActivityEventFilter.allCases,
                    selection: $kindFilter.value,
                    label: { $0.rawValue },
                    compact: true
                )
            }

            if filteredEvents.isEmpty {
                EmptyStateCard(
                    icon: "waveform.path.ecg",
                    title: model.recentActivities.isEmpty ? "暂无活动记录" : "当前筛选下无匹配记录",
                    description: model.recentActivities.isEmpty
                        ? "当采集、自动注入、主动检索或做梦批次发生时，持久化事件会按时间倒序实时记录在这里。"
                        : "尝试切换事件类型或 Agent 筛选条件查看全部活动。",
                    actionTitle: model.recentActivities.isEmpty ? nil : "重置筛选"
                ) {
                    kindFilter.value = .all
                    agentFilter.value = .all
                }
            } else {
                LazyVStack(alignment: .leading, spacing: 9) {
                    ForEach(filteredEvents) { event in
                        activityRow(event)
                    }
                }
            }
        }
    }

    private func activityRow(_ event: ActivityEvent) -> some View {
        let style = eventStyle(event.kind)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: style.icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(style.color)
                .frame(width: 30, height: 30)
                .background(style.color.opacity(theme.isDark ? 0.16 : 0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(style.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(theme.textPrimary)
                    if let agent = event.agent {
                        AgentTag(agent: agent.brand)
                    }
                    if let project = event.project, !project.isEmpty {
                        ScopeTag(projectPath: project)
                    }
                    Spacer()
                    Text(event.timestamp, format: .dateTime.month().day().hour().minute().second())
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(theme.textTertiary)
                }

                if let message = event.message, !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(event.kind == .error ? theme.danger : theme.textSecondary)
                        .lineLimit(3)
                }

                // Metrics & Batch pills
                let hitCount = event.count ?? (event.memoryIDs.isEmpty ? nil : event.memoryIDs.count)
                if hitCount != nil || event.estimatedTokens != nil || event.batchID != nil {
                    HStack(spacing: 6) {
                        if let hitCount {
                            ScorePill(
                                label: countLabel(for: event.kind),
                                value: "\(hitCount) 条",
                                tint: event.kind == .recall ? theme.success : theme.accent
                            )
                        }
                        if let tokens = event.estimatedTokens {
                            ScorePill(
                                label: "估算 Token",
                                value: "~\(tokens.formatted(.number))",
                                tint: theme.info
                            )
                        }
                        if let batchID = event.batchID, !batchID.isEmpty {
                            ScorePill(
                                label: "批次",
                                value: String(batchID.prefix(12)),
                                tint: theme.scopeGlobal
                            )
                        }
                    }
                }

                // Clickable Memory ID chips
                if !event.memoryIDs.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(event.memoryIDs, id: \.self) { memoryID in
                                let label = memoryTitleLookup[memoryID] ?? String(memoryID.prefix(10))
                                Button {
                                    onInspectMemoryID(memoryID)
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "doc.text.magnifyingglass")
                                            .font(.system(size: 10, weight: .semibold))
                                        Text(label)
                                            .font(.caption2.weight(.medium))
                                            .lineLimit(1)
                                    }
                                    .foregroundStyle(theme.accent)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3.5)
                                    .background(theme.accentSoft, in: Capsule())
                                    .overlay(Capsule().stroke(theme.accentBorder, lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                                .help("点击在右侧检查器查看记忆（ID: \(memoryID)）")
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(cornerRadius: 11, padding: 12)
    }

    private func countLabel(for kind: ActivityEvent.Kind) -> String {
        switch kind {
        case .scan: return "新增"
        case .recall: return "命中注入"
        case .search: return "命中"
        case .dreamClaim: return "领取"
        case .dreamSubmit: return "变更"
        case .dreamRollback: return "回滚"
        case .error: return "数量"
        }
    }

    private func eventStyle(_ kind: ActivityEvent.Kind) -> (title: String, icon: String, color: Color) {
        switch kind {
        case .scan:
            return ("采集扫描", "arrow.down.doc.fill", theme.info)
        case .recall:
            return ("自动注入", "bolt.fill", theme.success)
        case .search:
            return ("主动检索", "magnifyingglass", theme.accent)
        case .dreamClaim:
            return ("领取做梦批次", "moon.stars", theme.scopeGlobal)
        case .dreamSubmit:
            return ("提交做梦批次", "moon.stars.fill", theme.scopeGlobal)
        case .dreamRollback:
            return ("撤销做梦批次", "arrow.uturn.backward.circle.fill", theme.warning)
        case .error:
            return ("运行异常", "exclamationmark.triangle.fill", theme.danger)
        }
    }
}
