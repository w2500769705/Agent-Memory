import AgentMemoryCore
import SwiftUI

struct InspectorView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var model: AppModel
    let selection: AppPage
    @Binding var pickedDecision: Decision?

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
        .background(theme.inspectorBackground)
    }

    private var emptyInspector: some View {
        VStack(spacing: 12) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(theme.textTertiary)
            Text("详情检查器")
                .font(.headline)
                .foregroundStyle(theme.textPrimary)
            Text("在记忆列表或做梦队列中选择任意条目，即可查看正文、原始证据出处与版本演化。")
                .font(.callout)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 230)
        }
        .padding(24)
    }

    private func memoryInspector(_ hit: SearchHit) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        ScopeTag(projectPath: hit.memory.project)
                        ScorePill(label: "版本", value: "v\(hit.memory.version)", tint: theme.textPrimary)
                        if hit.memory.archived {
                            ScorePill(label: "状态", value: "已归档", tint: theme.warning)
                        } else if model.healthSummary.dormantMemoryIDs.contains(hit.id) {
                            ScorePill(label: "活性", value: "沉睡", tint: theme.warning)
                        }
                        Spacer()
                    }
                    Text(hit.memory.title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(theme.textPrimary)
                        .textSelection(.enabled)
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.caption2)
                        Text("更新于 ")
                        Text(Date(timeIntervalSince1970: hit.memory.updated), format: .dateTime.year().month().day().hour().minute())
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(theme.textTertiary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("命中与活跃统计")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.textSecondary)
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("累计命中")
                                .font(.caption2)
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
                                .font(.caption2)
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
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(theme.textSecondary)
                        HStack(spacing: 6) {
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
                    }
                    .surfaceCard(cornerRadius: 10, padding: 11)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("记忆正文")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.textSecondary)
                    Text(hit.memory.body)
                        .font(.callout)
                        .foregroundStyle(theme.textPrimary)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .surfaceCard(cornerRadius: 10, padding: 12)

                if let project = hit.memory.project, !project.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("所属项目路径")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(theme.textSecondary)
                        Text(project)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(theme.textSecondary)
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
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
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
                        Spacer()
                    }
                    Text(decision.proposal.title ?? "记忆提案")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(theme.textPrimary)
                    if !decision.proposal.reason.isEmpty {
                        Text(decision.proposal.reason)
                            .font(.callout)
                            .foregroundStyle(theme.textSecondary)
                    }
                }

                if let previous = model.previous {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("原版本 (v\(previous.version))")
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(theme.textSecondary)
                        Text(previous.body)
                            .font(.callout)
                            .foregroundStyle(theme.textPrimary)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .surfaceCard(cornerRadius: 10, padding: 12)
                }

                if let updated = decision.proposal.body {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("拟议版本")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(theme.accent)
                        Text(updated)
                            .font(.callout)
                            .foregroundStyle(theme.textPrimary)
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
                    .font(.caption)
                    .foregroundStyle(theme.textTertiary)
            } else {
                ForEach(model.evidence) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            ScopeTag(projectPath: item.project.isEmpty ? nil : item.project)
                            Spacer()
                            Text(Date(timeIntervalSince1970: item.timestamp), format: .dateTime.month().day().hour().minute())
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(theme.textTertiary)
                        }
                        Text(item.excerpt)
                            .font(.callout)
                            .foregroundStyle(theme.textPrimary)
                            .lineSpacing(2)
                            .textSelection(.enabled)
                        Text("\(item.threadID) / \(item.turnID)")
                            .font(.system(.caption2, design: .monospaced))
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
                            .font(.callout)
                            .foregroundStyle(theme.textPrimary)
                            .textSelection(.enabled)
                            .padding(.top, 4)
                        Text("批次 \(item.batchID)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(theme.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    HStack(spacing: 6) {
                        Text("v\(item.current.version)")
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(theme.accent)
                        Text(item.current.archived ? "已归档" : "有效")
                            .font(.caption)
                            .foregroundStyle(item.current.archived ? theme.warning : theme.textSecondary)
                        Spacer()
                        Text(Date(timeIntervalSince1970: item.current.updated), format: .dateTime.month().day().hour().minute())
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(theme.textTertiary)
                    }
                }
                .surfaceCard(cornerRadius: 10, padding: 10)
            }
        }
    }
}
