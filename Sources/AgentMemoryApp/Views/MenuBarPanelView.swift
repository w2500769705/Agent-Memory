import AgentMemoryCore
import AppKit
import SwiftUI

struct MenuBarPanelView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var model: AppModel
    let onOpenMainWindow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            metricsStrip
            todayRecallBar
            agentStatusList
            embeddingStrip
            if let error = model.error {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(theme.warning)
                        .font(.caption)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(2)
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.warningSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            Divider().overlay(theme.hairlineBorder)
            quickActions
        }
        .padding(14)
        .frame(width: 326)
        .background(theme.canvasBackground)
    }

    private var header: some View {
        let runtime = model.overallRuntimeStatus
        return HStack(spacing: 8) {
            Image(systemName: "circle.hexagongrid.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.accent)
            Text("Agent Memory")
                .font(.headline)
                .foregroundStyle(theme.textPrimary)
            Spacer()
            StatusCapsule(title: runtime.title, kind: runtime.kind, showSpinner: runtime.spinning)
        }
    }

    private var metricsStrip: some View {
        HStack(spacing: 8) {
            compactMetric("正式记忆", value: model.dashboard?.memories ?? 0, tint: theme.accent)
            compactMetric("待做梦", value: model.dashboard?.pending ?? 0, tint: theme.info)
            compactMetric("待确认", value: model.dashboard?.review ?? 0, tint: (model.dashboard?.review ?? 0) > 0 ? theme.warning : theme.success)
        }
    }

    private func compactMetric(_ label: String, value: Int, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(value)")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
            Text(label)
                .font(.caption2)
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(theme.surfacePrimary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(theme.hairlineBorder, lineWidth: 1)
        )
    }

    private var todayRecallBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.callout)
                .foregroundStyle(theme.success)
            VStack(alignment: .leading, spacing: 2) {
                Text("今日自动注入")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(theme.textSecondary)
                if let latestRecall = model.recentActivities.first(where: { $0.kind == .recall }) {
                    HStack(spacing: 4) {
                        Text("最近")
                        Text(latestRecall.timestamp, format: .dateTime.hour().minute())
                            .monospacedDigit()
                        if let count = latestRecall.count {
                            Text("· 命中 \(count) 条")
                                .monospacedDigit()
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(theme.textTertiary)
                } else {
                    Text("尚无自动注入命中")
                        .font(.caption2)
                        .foregroundStyle(theme.textTertiary)
                }
            }
            Spacer()
            HStack(spacing: 6) {
                ScorePill(label: "次", value: "\(model.todayRecallCount)", tint: theme.textPrimary)
                ScorePill(label: "tok", value: "~\(model.todayRecallEstimatedTokens.formatted(.number))", tint: theme.accent)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(theme.surfacePrimary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(theme.hairlineBorder, lineWidth: 1)
        )
    }

    private var agentStatusList: some View {
        VStack(spacing: 8) {
            agentRow(
                brand: .codex,
                enabled: model.enabled,
                captureState: model.runtimeHealth.codexCapture,
                connected: model.connection?.toolsAvailable == true,
                detail: model.status.isEmpty ? (model.enabled ? "已开启增量采集" : "采集已暂停") : model.status
            ) {
                model.capture(!model.enabled)
            }
            agentRow(
                brand: .antigravity,
                enabled: model.antigravityEnabled,
                captureState: model.runtimeHealth.antigravityCapture,
                connected: model.antigravityConnection?.toolsAvailable == true,
                detail: model.antigravityStatus.isEmpty ? (model.antigravityEnabled ? "已开启增量采集" : "采集已暂停") : model.antigravityStatus
            ) {
                model.captureAntigravity(!model.antigravityEnabled)
            }
        }
    }

    private func agentRow(
        brand: AgentBrand,
        enabled: Bool,
        captureState: RuntimeHealth.CaptureState,
        connected: Bool,
        detail: String,
        onToggle: @escaping () -> Void
    ) -> some View {
        let capture = captureState.presentation(smartCapture: model.smartCapture)
        return HStack(spacing: 10) {
            Circle()
                .fill(capture.kind.color(in: theme))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(brand.rawValue)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(theme.textPrimary)
                    if connected {
                        Text("MCP")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(theme.success)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(theme.successSoft, in: Capsule())
                    }
                    Text(capture.title)
                        .font(.caption2)
                        .foregroundStyle(theme.textTertiary)
                }
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            if capture.spinning {
                ProgressView().controlSize(.mini)
            } else {
                Button(enabled ? "暂停" : "启用", action: onToggle)
                    .controlSize(.small)
                    .disabled(model.store == nil)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(theme.surfacePrimary, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(theme.hairlineBorder, lineWidth: 1)
        )
    }

    private var embeddingStrip: some View {
        let embedding = model.runtimeHealth.embedding.presentation
        return HStack(spacing: 8) {
            Image(systemName: "cpu")
                .font(.caption)
                .foregroundStyle(theme.textSecondary)
            Text("本地向量")
                .font(.caption)
                .foregroundStyle(theme.textSecondary)
            Spacer()
            StatusCapsule(title: embedding.title, kind: embedding.kind, showSpinner: embedding.spinning)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(theme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(theme.hairlineBorder, lineWidth: 1)
        )
    }

    private var quickActions: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    onOpenMainWindow()
                } label: {
                    Label("打开主窗口", systemImage: "macwindow")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryActionButtonStyle(compact: true))

                Button {
                    Task { await model.scanAllEnabled(force: true) }
                } label: {
                    Label("立即扫描", systemImage: "arrow.clockwise")
                }
                .buttonStyle(SoftActionButtonStyle(compact: true))
                .disabled(!model.isAnySourceEnabled || model.isAnyScanning || model.store == nil)
            }

            HStack {
                Button {
                    let shouldEnable = !model.isAnySourceEnabled
                    model.capture(shouldEnable)
                    model.captureAntigravity(shouldEnable)
                } label: {
                    Label(
                        model.isAnySourceEnabled ? "全部暂停采集" : "恢复全部采集",
                        systemImage: model.isAnySourceEnabled ? "pause.circle" : "play.circle"
                    )
                    .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.textSecondary)
                .disabled(model.store == nil)

                Spacer()

                Button("退出") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(theme.textTertiary)
            }
            .padding(.top, 2)
        }
    }
}
