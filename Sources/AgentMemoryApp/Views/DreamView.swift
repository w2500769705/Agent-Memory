import AgentMemoryCore
import SwiftUI

struct DreamView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var model: AppModel
    @Binding var pickedDecision: Decision?
    @Binding var pendingUndo: String?
    @Binding var focusProposals: Bool
    let onInspectDecision: (Decision) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    headerRow

                    if let dashboard = model.dashboard {
                        if dashboard.decisions.isEmpty && dashboard.evidence.isEmpty && dashboard.batchSummaries.isEmpty {
                            EmptyStateCard(
                                icon: "moon.stars",
                                title: "暂无待处理记录",
                                description: "当 Codex 或 Antigravity 产生新的对话记录时，会自动进入待做梦队列。"
                            )
                        }

                        if !dashboard.decisions.isEmpty {
                            proposalsSection(dashboard.decisions)
                                .id("dream-proposals")
                        }

                        if !dashboard.evidence.isEmpty {
                            pendingEvidenceSection(dashboard.evidence)
                        }

                        if !dashboard.batchSummaries.isEmpty {
                            batchHistorySection(dashboard.batchSummaries)
                        }
                    }
                }
                .padding(24)
            }
            .background(Color.clear)
            .task(id: focusProposals) {
                guard focusProposals else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo("dream-proposals", anchor: .top)
                }
                focusProposals = false
            }
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("做梦中心")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(theme.textPrimary)
                Text("将新采集的对话证据交由 Agent 提炼、去重并沉淀为长期记忆")
                    .font(.callout)
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer()
            Button("复制做梦指令") {
                model.copyDreamInstructions()
            }
            .buttonStyle(SoftActionButtonStyle())
            Button {
                model.copyBatchDream()
            } label: {
                Label("批量做梦", systemImage: "moon.stars")
            }
            .buttonStyle(PrimaryActionButtonStyle())
            .disabled(model.dashboard?.queuedThrough == nil)
            .help("复制批量做梦指令，粘贴到 Agent 中处理当前待做梦记录")
        }
    }

    // MARK: - Pending & Conflict Proposals (Side-by-Side Diff)

    private func proposalsSection(_ decisions: [Decision]) -> some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            SectionHeader("待确认与冲突提案", count: decisions.count) {
                Text("并排对比旧版本与拟议变更，可逐条确认或拒绝")
                    .font(.caption)
                    .foregroundStyle(theme.textTertiary)
            }

            ForEach(decisions) { decision in
                DreamProposalDiffCard(
                    model: model,
                    decision: decision,
                    isSelected: pickedDecision?.id == decision.id,
                    onInspect: { onInspectDecision(decision) },
                    onReview: { accept in
                        model.review(decision, accept: accept)
                        if pickedDecision?.id == decision.id {
                            pickedDecision = nil
                        }
                    }
                )
            }
        }
    }

    // MARK: - Pending Evidence Queue

    private func pendingEvidenceSection(_ evidence: [Evidence]) -> some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            SectionHeader("待做梦记录", count: evidence.count)
            ForEach(evidence) { record in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            ScopeTag(projectPath: record.project.isEmpty ? nil : record.project)
                            Text(Date(timeIntervalSince1970: record.timestamp), format: .dateTime.month().day().hour().minute())
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(theme.textTertiary)
                        }
                        Text(record.excerpt)
                            .lineLimit(3)
                            .font(.callout)
                            .foregroundStyle(theme.textPrimary)
                    }
                    Spacer()
                    Menu {
                        Button("排除此聊天") { model.exclude(record, byProject: false) }
                        Button("排除此项目") { model.exclude(record, byProject: true) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(theme.textSecondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("记录操作")
                }
                .surfaceCard(cornerRadius: 11, padding: 12)
            }
        }
    }

    // MARK: - Batch History

    private func batchHistorySection(_ summaries: [DreamBatchSummary]) -> some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            SectionHeader("批次历史", count: summaries.count)
            ForEach(summaries) { summary in
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: summary.conflictCount > 0 ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                        .font(.callout)
                        .foregroundStyle(summary.conflictCount > 0 ? theme.warning : theme.success)

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text(summary.batchID)
                                .font(.system(.callout, design: .monospaced).weight(.medium))
                                .foregroundStyle(theme.textPrimary)
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(Date(timeIntervalSince1970: summary.createdAt), format: .dateTime.month().day().hour().minute())
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(theme.textTertiary)
                        }

                        HStack(spacing: 6) {
                            ScorePill(
                                label: "已应用",
                                value: "\(summary.appliedCount)",
                                tint: summary.appliedCount > 0 ? theme.success : theme.textTertiary
                            )
                            ScorePill(
                                label: "待确认",
                                value: "\(summary.pendingCount)",
                                tint: summary.pendingCount > 0 ? theme.warning : theme.textTertiary
                            )
                            ScorePill(
                                label: "冲突",
                                value: "\(summary.conflictCount)",
                                tint: summary.conflictCount > 0 ? theme.danger : theme.textTertiary
                            )
                        }
                    }

                    Spacer()

                    Button {
                        pendingUndo = summary.batchID
                    } label: {
                        Label("整批撤销", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(SoftActionButtonStyle(tint: summary.canRollback ? theme.warning : nil, compact: true))
                    .disabled(!summary.canRollback)
                    .help(summary.canRollback ? "回滚此批次应用的所有记忆变更" : "此批次无可回滚变更，或其中记忆已被后续批次修改")
                }
                .surfaceCard(cornerRadius: 11, padding: 12)
            }
        }
    }
}

// MARK: - Proposal Side-by-Side Diff Card

@MainActor
private final class ProposalDiffLoader: ObservableObject {
    @Published var previousMemory: Memory?
    @Published var citedEvidence: [Evidence] = []
    private var loadedDecisionID: String?

    func loadIfNeeded(decision: Decision, store: MemoryStore?) async {
        guard loadedDecisionID != decision.id else { return }
        loadedDecisionID = decision.id
        guard let store else {
            previousMemory = nil
            citedEvidence = []
            return
        }

        let memoryID = decision.proposal.memoryID
        let expectedVersion = decision.proposal.expectedVersion
        let evidenceIDs = decision.proposal.evidenceIDs

        let result = await Task.detached(priority: .userInitiated) { () -> (Memory?, [Evidence]) in
            var oldMem: Memory? = nil
            if let id = memoryID {
                if let expected = expectedVersion,
                   let exact = try? store.memory(id: id, version: expected) {
                    oldMem = exact
                } else {
                    oldMem = try? store.memory(id: id, version: nil)
                }
            }
            let ev: [Evidence] = evidenceIDs.isEmpty ? [] : ((try? store.evidence(evidenceIDs)) ?? [])
            return (oldMem, ev)
        }.value

        guard !Task.isCancelled else { return }
        previousMemory = result.0
        citedEvidence = result.1
    }
}

private struct DreamProposalDiffCard: View {
    @Environment(\.theme) private var theme
    @ObservedObject var model: AppModel
    let decision: Decision
    let isSelected: Bool
    let onInspect: () -> Void
    let onReview: (Bool) -> Void

    @StateObject private var showEvidence = LocalState(true)
    @StateObject private var loader = ProposalDiffLoader()

    private var operationBadge: (label: String, tint: Color) {
        switch decision.proposal.operation {
        case .add: return ("新增", theme.success)
        case .update: return ("更新", theme.info)
        case .archive: return ("归档", theme.warning)
        case .skip: return ("跳过", theme.textSecondary)
        }
    }

    private var statusBadge: (label: String, tint: Color) {
        switch decision.status.lowercased() {
        case "review": return ("待确认", theme.warning)
        case "conflict": return ("版本冲突", theme.danger)
        case "applied": return ("已应用", theme.success)
        case "rejected": return ("已拒绝", theme.textTertiary)
        default: return (decision.status, theme.textSecondary)
        }
    }

    private var proposedScopePath: String? {
        if let project = decision.proposal.project, !project.isEmpty {
            return project
        }
        return loader.previousMemory?.project
    }

    var body: some View {
        let oldMemory = loader.previousMemory
        let evidenceList = loader.citedEvidence
        let op = operationBadge
        let st = statusBadge

        VStack(alignment: .leading, spacing: 12) {
            // Top bar: badges, title, actions
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        ScorePill(label: "操作", value: op.label, tint: op.tint)
                        ScorePill(label: "状态", value: st.label, tint: st.tint)
                        ScopeTag(projectPath: proposedScopePath)
                        if let expected = decision.proposal.expectedVersion {
                            ScorePill(label: "基线", value: "v\(expected)", tint: theme.textSecondary)
                        }
                    }

                    Text(decision.proposal.title ?? oldMemory?.title ?? decision.proposal.operation.rawValue)
                        .font(.headline)
                        .foregroundStyle(theme.textPrimary)

                    if !decision.message.isEmpty || !decision.proposal.reason.isEmpty {
                        Text(decision.message.isEmpty ? decision.proposal.reason : decision.message)
                            .font(.caption)
                            .foregroundStyle(theme.textSecondary)
                    }
                }

                Spacer(minLength: 10)

                HStack(spacing: 8) {
                    Button {
                        onInspect()
                    } label: {
                        Label("详情", systemImage: "sidebar.right")
                    }
                    .buttonStyle(SoftActionButtonStyle(compact: true))
                    .help("在右侧检查器查看完整版本与证据")

                    if decision.status == "review" {
                        Button("拒绝") {
                            onReview(false)
                        }
                        .buttonStyle(SoftActionButtonStyle(tint: theme.danger, compact: true))
                        Button("确认写入") {
                            onReview(true)
                        }
                        .buttonStyle(PrimaryActionButtonStyle(compact: true))
                    }
                }
            }

            // Side-by-Side Diff Panel
            HStack(alignment: .top, spacing: 10) {
                oldContentPane(oldMemory)
                proposedContentPane(oldMemory)
            }
            .fixedSize(horizontal: false, vertical: true)

            // Cited Evidence Excerpts
            if !evidenceList.isEmpty {
                DisclosureGroup(isExpanded: $showEvidence.value) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(evidenceList) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    ScopeTag(projectPath: item.project.isEmpty ? nil : item.project)
                                    Text(Date(timeIntervalSince1970: item.timestamp), format: .dateTime.month().day().hour().minute())
                                        .font(.caption2)
                                        .monospacedDigit()
                                        .foregroundStyle(theme.textTertiary)
                                    Spacer()
                                    Text("\(item.threadID.prefix(10))")
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(theme.textTertiary)
                                }
                                Text(item.excerpt)
                                    .font(.caption)
                                    .foregroundStyle(theme.textPrimary)
                                    .lineLimit(3)
                                    .textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(9)
                            .background(theme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(theme.hairlineBorder, lineWidth: 1)
                            )
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "quote.opening")
                            .font(.caption2)
                            .foregroundStyle(theme.accent)
                        Text("引用证据摘录")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(theme.textSecondary)
                        Text("\(evidenceList.count)")
                            .font(.caption2.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(theme.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(theme.surfaceSecondary, in: Capsule())
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceCard(cornerRadius: 12, padding: 14, highlighted: isSelected)
        .task(id: decision.id) {
            await loader.loadIfNeeded(decision: decision, store: model.store)
        }
    }

    private func oldContentPane(_ oldMemory: Memory?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "doc.plaintext")
                    .font(.caption2)
                    .foregroundStyle(theme.textTertiary)
                if let oldMemory {
                    Text("旧内容 · v\(oldMemory.version)")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(theme.textSecondary)
                } else {
                    Text("旧内容")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer()
            }

            if let oldMemory {
                if let proposedTitle = decision.proposal.title, proposedTitle != oldMemory.title {
                    Text(oldMemory.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.textSecondary)
                        .strikethrough(true, color: theme.danger.opacity(0.6))
                }
                Text(oldMemory.body)
                    .font(.callout)
                    .foregroundStyle(theme.textSecondary)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(decision.proposal.operation == .add ? "新增记忆，无历史旧版本。" : "未找到对应的历史版本快照。")
                    .font(.caption)
                    .foregroundStyle(theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(11)
        .background(theme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(theme.hairlineBorder, lineWidth: 1)
        )
    }

    private func proposedContentPane(_ oldMemory: Memory?) -> some View {
        let tint: Color = switch decision.proposal.operation {
        case .add: theme.success
        case .update: theme.accent
        case .archive: theme.warning
        case .skip: theme.textSecondary
        }

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: decision.proposal.operation == .archive ? "archivebox" : "sparkles")
                    .font(.caption2)
                    .foregroundStyle(tint)
                Text(decision.proposal.operation == .archive ? "拟议归档" : "拟议变更")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                Spacer()
            }

            if decision.proposal.operation == .archive {
                Text("将把该记忆标记为「已归档」，后续不再参与常规召回，但保留历史版本可追溯。")
                    .font(.callout)
                    .foregroundStyle(theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !decision.proposal.reason.isEmpty {
                    Text("原因：\(decision.proposal.reason)")
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                }
            } else if let proposedBody = decision.proposal.body, !proposedBody.isEmpty {
                if let proposedTitle = decision.proposal.title,
                   let oldTitle = oldMemory?.title,
                   proposedTitle != oldTitle {
                    Text(proposedTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                }
                Text(proposedBody)
                    .font(.callout)
                    .foregroundStyle(theme.textPrimary)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("无正文变更。")
                    .font(.caption)
                    .foregroundStyle(theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(11)
        .background(tint.opacity(theme.isDark ? 0.11 : 0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(tint.opacity(0.32), lineWidth: 1)
        )
    }
}
