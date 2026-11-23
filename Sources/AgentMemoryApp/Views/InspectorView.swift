import AgentMemoryCore
import SwiftUI

struct InspectorView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var model: AppModel
    let selection: AppPage
    @Binding var pickedDecision: Decision?
    var onClose: (() -> Void)? = nil

    @StateObject private var showFullReader = LocalState(false)

    private var activeMemoryHit: SearchHit? {
        if selection == .memory, let hit = model.selectedMemory {
            return hit
        } else if selection == .dream, pickedDecision != nil {
            return nil
        } else if let hit = model.selectedMemory {
            return hit
        }
        return nil
    }

    var body: some View {
        Group {
            if selection == .memory, let hit = model.selectedMemory {
                memoryInspector(hit)
            } else if selection == .dream, let decision = pickedDecision {
                decisionInspector(decision)
            } else if let hit = model.selectedMemory {
                memoryInspector(hit)
            } else {
                emptyInspector
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .sheet(isPresented: $showFullReader.value) {
            if let hit = activeMemoryHit {
                MemoryFullReaderSheet(
                    hit: hit,
                    model: model,
                    onClose: { showFullReader.value = false }
                )
                .applyTheme(model.themeMode)
            }
        }
    }

    private var emptyInspector: some View {
        VStack(spacing: 0) {
            HStack {
                Text("详情检查器")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                if let onClose {
                    closeDrawerButton(action: onClose)
                }
            }
            .padding(16)

            Spacer()

            VStack(spacing: 12) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(theme.textTertiary)
                Text("详情检查器")
                    .font(.headline)
                    .foregroundStyle(theme.textPrimary)
                Text("在记忆列表、3D 星图或做梦队列中选择任意条目，即可查看正文、原始证据出处与版本演化。")
                    .font(.callout)
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 240)
            }
            .padding(24)

            Spacer()
        }
    }

    private func closeDrawerButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 26, height: 26)
                .background(theme.surfaceSecondary.opacity(theme.isDark ? 0.65 : 0.80), in: Circle())
                .overlay(Circle().stroke(theme.hairlineBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("关闭详情抽屉")
        .accessibilityLabel("关闭详情抽屉")
    }

    private func memoryInspector(_ hit: SearchHit) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Text("记忆详情")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                    Spacer()
                    if hit.memory.archived {
                        Button {
                            model.archiveMemory(id: hit.id, archived: false)
                            if model.selectedMemory == nil { onClose?() }
                        } label: {
                            Label("恢复", systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(SoftActionButtonStyle(tint: theme.success, compact: true))
                        .help("取消归档并恢复为活跃记忆")

                        DeleteArchivedMemoryButton(title: hit.memory.title) {
                            model.deleteArchivedMemory(id: hit.id)
                            if model.selectedMemory == nil { onClose?() }
                        }
                        .id(hit.id)
                    } else {
                        Button {
                            model.archiveMemory(id: hit.id, archived: true)
                        } label: {
                            Label("归档", systemImage: "archivebox")
                        }
                        .buttonStyle(SoftActionButtonStyle(tint: theme.warning, compact: true))
                        .help("归档此记忆，后续不再参与常规召回（可随时恢复）")
                    }

                    Button {
                        showFullReader.value = true
                    } label: {
                        Label("大屏阅读", systemImage: "arrow.up.left.and.arrow.down.right")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(SoftActionButtonStyle(tint: theme.accent, compact: true))
                    .help("在居中大阅读浮窗中查看完整记忆内容与证据")

                    if let onClose {
                        closeDrawerButton(action: onClose)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        ScopeTag(projectPath: hit.memory.project)
                        ScorePill(label: "版本", value: "v\(hit.memory.version)", tint: theme.textPrimary)
                        if hit.memory.archived {
                            ScorePill(label: "状态", value: "已归档", tint: theme.warning)
                        } else if model.healthSummary.dormantMemoryIDs.contains(hit.id) {
                            ScorePill(label: "活性", value: "沉睡", tint: theme.warning)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(hit.memory.title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)

                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.system(size: 11.5))
                        Text("更新于 ")
                        Text(Date(timeIntervalSince1970: hit.memory.updated), format: .dateTime.year().month().day().hour().minute())
                            .monospacedDigit()
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textTertiary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("命中与活跃统计")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("累计命中")
                                .font(.system(size: 11.5))
                                .foregroundStyle(theme.textTertiary)
                            Text("\(hit.memory.hitCount) 次")
                                .font(.callout.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(hit.memory.hitCount > 0 ? theme.accent : theme.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Rectangle()
                            .fill(theme.hairlineBorder)
                            .frame(width: 1, height: 28)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("最近命中")
                                .font(.system(size: 11.5))
                                .foregroundStyle(theme.textTertiary)
                            if let lastHitAt = hit.memory.lastHitAt {
                                Text(Date(timeIntervalSince1970: lastHitAt), format: .dateTime.month().day().hour().minute())
                                    .font(.callout.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(theme.textPrimary)
                            } else {
                                Text("从未命中")
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(theme.textTertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .surfaceCard(cornerRadius: 10, padding: 11)

                if hit.vector != nil || hit.keywordRank != nil || hit.score > 0 {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("检索匹配得分")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.textSecondary)
                        FlowLayout(spacing: 6, lineSpacing: 6) {
                            if let vector = hit.vector {
                                ScorePill(label: "Vector", value: String(format: "%.3f", vector), tint: theme.accent)
                            }
                            if let rank = hit.keywordRank {
                                ScorePill(label: "BM25", value: "#\(rank)", tint: theme.info)
                            }
                            if hit.score > 0 {
                                ScorePill(label: "RRF", value: String(format: "%.4f", hit.score), tint: theme.success)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .surfaceCard(cornerRadius: 10, padding: 11)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("记忆正文")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                    Text(hit.memory.body)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textPrimary)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .surfaceCard(cornerRadius: 10, padding: 12)

                if let project = hit.memory.project, !project.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("所属项目路径")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.textSecondary)
                        Text(project)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .surfaceCard(cornerRadius: 10, padding: 10)
                }

                Divider().overlay(theme.hairlineBorder)

                evidenceSection

                if !model.history.isEmpty {
                    Divider().overlay(theme.hairlineBorder)
                    versionHistorySection
                }
            }
            .padding(16)
        }
    }

    private func decisionInspector(_ decision: Decision) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Text("提案详情")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                    Spacer()
                    if let onClose {
                        closeDrawerButton(action: onClose)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        ScorePill(
                            label: "操作",
                            value: decision.proposal.operation.rawValue.uppercased(),
                            tint: theme.accent
                        )
                        ScorePill(
                            label: "状态",
                            value: decision.status == "review" ? "待确认" : decision.status,
                            tint: decision.status == "review" ? theme.warning : theme.textSecondary
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(decision.proposal.title ?? "记忆提案")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)

                    if !decision.proposal.reason.isEmpty {
                        Text(decision.proposal.reason)
                            .font(.callout)
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if let previous = model.previous {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("原版本 (v\(previous.version))")
                            .font(.system(size: 12, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(theme.textSecondary)
                        Text(previous.body)
                            .font(.system(size: 13))
                            .foregroundStyle(theme.textPrimary)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .surfaceCard(cornerRadius: 10, padding: 12)
                }

                if let updated = decision.proposal.body {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("拟议版本")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.accent)
                        Text(updated)
                            .font(.system(size: 13))
                            .foregroundStyle(theme.textPrimary)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .surfaceCard(cornerRadius: 10, padding: 12, highlighted: true)
                }

                if decision.status == "review" {
                    HStack(spacing: 10) {
                        Button("拒绝") {
                            model.review(decision, accept: false)
                            pickedDecision = nil
                        }
                        .buttonStyle(SoftActionButtonStyle(tint: theme.danger))
                        .frame(maxWidth: .infinity)
                        Button("确认写入") {
                            model.review(decision, accept: true)
                            pickedDecision = nil
                        }
                        .buttonStyle(PrimaryActionButtonStyle())
                        .frame(maxWidth: .infinity)
                    }
                }

                Divider().overlay(theme.hairlineBorder)

                evidenceSection
            }
            .padding(16)
        }
    }

    private var evidenceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("引用证据", count: model.evidence.count)
            if model.evidence.isEmpty {
                Text("暂无关联的原始对话证据。")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textTertiary)
            } else {
                ForEach(model.evidence) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        FlowLayout(spacing: 6, lineSpacing: 4) {
                            ScopeTag(projectPath: item.project.isEmpty ? nil : item.project)
                            Text(Date(timeIntervalSince1970: item.timestamp), format: .dateTime.month().day().hour().minute())
                                .font(.system(size: 11.5))
                                .monospacedDigit()
                                .foregroundStyle(theme.textTertiary)
                                .padding(.vertical, 3)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Text(item.excerpt)
                            .font(.system(size: 12.5))
                            .foregroundStyle(theme.textPrimary)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)

                        Text("\(item.threadID) / \(item.turnID)")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .surfaceCard(cornerRadius: 10, padding: 10)
                }
            }
        }
    }

    private var versionHistorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("版本演化", count: model.history.count)
            ForEach(model.history) { item in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.current.body)
                            .font(.system(size: 12.5))
                            .foregroundStyle(theme.textPrimary)
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(.top, 4)
                        Text("批次 \(item.batchID)")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(theme.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    HStack(spacing: 6) {
                        Text("v\(item.current.version)")
                            .font(.system(size: 12, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(theme.accent)
                        Text(item.current.archived ? "已归档" : "有效")
                            .font(.system(size: 12))
                            .foregroundStyle(item.current.archived ? theme.warning : theme.textSecondary)
                        Spacer()
                        Text(Date(timeIntervalSince1970: item.current.updated), format: .dateTime.month().day().hour().minute())
                            .font(.system(size: 11.5))
                            .monospacedDigit()
                            .foregroundStyle(theme.textTertiary)
                    }
                }
                .surfaceCard(cornerRadius: 10, padding: 10)
            }
        }
    }
}

// MARK: - Centered Large Reading Modal Sheet (680×560)

private struct MemoryFullReaderSheet: View {
    @Environment(\.theme) private var theme
    let hit: SearchHit
    @ObservedObject var model: AppModel
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top bar
            HStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 30, height: 30)
                    .background(theme.accentSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text("记忆大屏阅读")
                        .font(.headline)
                        .foregroundStyle(theme.textPrimary)
                    HStack(spacing: 6) {
                        Text("更新于 ")
                        Text(Date(timeIntervalSince1970: hit.memory.updated), format: .dateTime.year().month().day().hour().minute())
                            .monospacedDigit()
                        Text("· 累计命中 \(hit.memory.hitCount) 次")
                            .monospacedDigit()
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
                }

                Spacer()

                Button("关闭", action: onClose)
                    .buttonStyle(SoftActionButtonStyle())
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .background(theme.surfacePrimary)
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.hairlineBorder).frame(height: 1)
            }

            // Scrollable reading content
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        FlowLayout(spacing: 6, lineSpacing: 6) {
                            ScopeTag(projectPath: hit.memory.project)
                            ScorePill(label: "版本", value: "v\(hit.memory.version)", tint: theme.textPrimary)
                            if hit.memory.archived {
                                ScorePill(label: "状态", value: "已归档", tint: theme.warning)
                            } else if model.healthSummary.dormantMemoryIDs.contains(hit.id) {
                                ScorePill(label: "活性", value: "沉睡", tint: theme.warning)
                            }
                            if let vector = hit.vector {
                                ScorePill(label: "Vector", value: String(format: "%.3f", vector), tint: theme.accent)
                            }
                            if let rank = hit.keywordRank {
                                ScorePill(label: "BM25", value: "#\(rank)", tint: theme.info)
                            }
                            if hit.score > 0 {
                                ScorePill(label: "RRF", value: String(format: "%.4f", hit.score), tint: theme.success)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Text(hit.memory.title)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("记忆正文")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(theme.textSecondary)
                        Text(hit.memory.body)
                            .font(.system(size: 14))
                            .foregroundStyle(theme.textPrimary)
                            .lineSpacing(5)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .surfaceCard(cornerRadius: 12, padding: 16)

                    if let project = hit.memory.project, !project.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("所属项目路径")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(theme.textSecondary)
                            Text(project)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .surfaceCard(cornerRadius: 10, padding: 12)
                    }

                    if !model.evidence.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeader("引用证据", count: model.evidence.count)
                            ForEach(model.evidence) { item in
                                VStack(alignment: .leading, spacing: 7) {
                                    FlowLayout(spacing: 6, lineSpacing: 4) {
                                        ScopeTag(projectPath: item.project.isEmpty ? nil : item.project)
                                        Text(Date(timeIntervalSince1970: item.timestamp), format: .dateTime.year().month().day().hour().minute())
                                            .font(.system(size: 12))
                                            .monospacedDigit()
                                            .foregroundStyle(theme.textTertiary)
                                            .padding(.vertical, 3)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                    Text(item.excerpt)
                                        .font(.system(size: 13.5))
                                        .foregroundStyle(theme.textPrimary)
                                        .lineSpacing(4)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)

                                    Text("\(item.threadID) / \(item.turnID)")
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .foregroundStyle(theme.textTertiary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .textSelection(.enabled)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .surfaceCard(cornerRadius: 10, padding: 12)
                            }
                        }
                    }

                    if !model.history.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeader("版本演化", count: model.history.count)
                            ForEach(model.history) { item in
                                DisclosureGroup {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(item.current.body)
                                            .font(.system(size: 13))
                                            .foregroundStyle(theme.textPrimary)
                                            .lineSpacing(4)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .textSelection(.enabled)
                                            .padding(.top, 6)
                                        Text("批次 \(item.batchID)")
                                            .font(.system(size: 11.5, design: .monospaced))
                                            .foregroundStyle(theme.textTertiary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                } label: {
                                    HStack(spacing: 8) {
                                        Text("v\(item.current.version)")
                                            .font(.system(size: 12.5, weight: .semibold))
                                            .monospacedDigit()
                                            .foregroundStyle(theme.accent)
                                        Text(item.current.archived ? "已归档" : "有效")
                                            .font(.system(size: 12))
                                            .foregroundStyle(item.current.archived ? theme.warning : theme.textSecondary)
                                        Spacer()
                                        Text(Date(timeIntervalSince1970: item.current.updated), format: .dateTime.year().month().day().hour().minute())
                                            .font(.system(size: 12))
                                            .monospacedDigit()
                                            .foregroundStyle(theme.textTertiary)
                                    }
                                }
                                .surfaceCard(cornerRadius: 10, padding: 12)
                            }
                        }
                    }
                }
                .padding(22)
            }
        }
        .frame(width: 680, height: 560)
        .background(theme.canvasBackground)
    }
}
