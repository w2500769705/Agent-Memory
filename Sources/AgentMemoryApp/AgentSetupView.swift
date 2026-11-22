import SwiftUI

@MainActor
private final class SetupCopyState: ObservableObject {
    @Published var copied = false
    @Published var copiedVerify = false
    @Published var antigravityConnectRequested = false
}

struct AgentSetupView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var model: AppModel
    @Binding var selectedAgent: AgentBrand
    @StateObject private var copyState = SetupCopyState()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: selectedAgent.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selectedAgent.color(in: theme))
                        .frame(width: 26, height: 26)
                        .background(selectedAgent.softColor(in: theme), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    Text("连接与自动检索引导")
                        .font(.headline)
                        .foregroundStyle(theme.textPrimary)
                }
                Spacer()
                if (selectedAgent == .codex && model.checkingConnection) ||
                    (selectedAgent == .antigravity && model.checkingAntigravity) {
                    ProgressView().controlSize(.small)
                }
                Picker("Agent", selection: $selectedAgent) {
                    ForEach(AgentBrand.allCases) { agent in
                        Text(agent.rawValue).tag(agent)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 218)
                .accessibilityLabel("选择 Agent")
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .font(.caption)
                    .foregroundStyle(theme.info)
                    .padding(.top, 1)
                Text("定位说明：Agent Memory 负责跨 Agent 共享、可溯源的长期技术与偏好记忆；为避免上下文冗余或冲突，建议关闭或精简宿主自带的自动记忆功能。")
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.infoSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(theme.info.opacity(0.24), lineWidth: 1)
            )

            switch selectedAgent {
            case .codex: codexSteps
            case .antigravity: antigravitySteps
            }
        }
        .padding(4)
        .task {
            verifyCurrentAgentIfNeeded()
        }
        .onChange(of: selectedAgent) { _, agent in
            copyState.copied = false
            copyState.copiedVerify = false
            switch agent {
            case .codex: model.configureCodex()
            case .antigravity: model.configureAntigravity()
            }
        }
    }

    private func verifyCurrentAgentIfNeeded() {
        switch selectedAgent {
        case .codex:
            if model.connection == nil { model.configureCodex() }
        case .antigravity:
            if model.antigravityConnection == nil { model.configureAntigravity() }
        }
    }

    private var codexSteps: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                state(
                    "连接 MCP",
                    detail: model.connection?.toolsAvailable == true ? "Codex 已发现搜索、领取和写回工具" :
                        model.connection?.registered == true ? "已注册，等待工具可用" :
                        model.checkingConnection ? "正在检查 Codex 配置" : "待连接或验证",
                    verified: model.connection?.toolsAvailable == true
                )
                Spacer()
                if model.connection?.registered != true {
                    Button("连接 Codex") { model.configureCodex(.connect) }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.checkingConnection || model.store == nil)
                }
                Button("验证连接") { model.configureCodex() }
                    .disabled(model.checkingConnection || model.store == nil)
            }
            Divider().overlay(theme.hairlineBorder)
            HStack {
                state("采集聊天",
                      detail: model.status.isEmpty ? (model.enabled ? "已启用，等待首次扫描" : "从启用时开始增量收录") : model.status,
                      verified: model.enabled && model.lastScan != nil)
                Spacer()
                if model.scanning { ProgressView().controlSize(.small) }
                Button(model.enabled ? "立即扫描" : "启用采集") {
                    if model.enabled { Task { await model.scan(force: true) } }
                    else { model.capture(true) }
                }
                .disabled(model.scanning || model.store == nil)
            }
            Divider().overlay(theme.hairlineBorder)
            HStack(alignment: .top) {
                state("自动检索",
                      detail: recallStatus,
                      verified: recallVerified)
                Spacer()
                if model.recallEnabled {
                    if model.connection?.recallInstalled == true {
                        if !recallVerified {
                            Button("在终端审核") { model.openHookReview() }
                        }
                        Button(recallVerified ? "再次验证" : "打开 Codex 验证") { model.openRecallTest() }
                    } else {
                        Button("修复 Hook 配置") { model.configureCodex(.enableRecall) }
                            .disabled(model.checkingConnection)
                    }
                    Button("关闭") { model.configureCodex(.disableRecall) }
                        .disabled(model.checkingConnection)
                        .accessibilityLabel("关闭自动检索")
                } else {
                    Button("配置自动检索") { model.configureCodex(.enableRecall) }
                        .disabled(model.checkingConnection || model.connection?.toolsAvailable != true)
                }
            }
            if let date = model.recallVerifiedAt, recallVerified {
                Text("最近一次验证 " + date.formatted(.dateTime.month().day().hour().minute()))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(theme.textSecondary)
                    .padding(.leading, 23)
            } else if model.recallEnabled, model.connection?.recallInstalled == true {
                Text("在 Codex 的「设置 → 勾子（Hooks）」审核 Agent Memory 的 UserPromptSubmit，再回到这里发送验证指令。也可以通过「在终端审核」完成。")
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .padding(.leading, 23)
            }
            if let error = model.setupError ?? model.connection?.hookError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(theme.warning)
            }
            HStack {
                Button(copyState.copied ? "已复制配置指令" : "复制给 Codex 配置") {
                    model.copyAgentSetupInstructions()
                    copyState.copied = true
                }
                .buttonStyle(.link)
                .disabled(model.store == nil)
                if copyState.copied {
                    Text("粘贴到本地 Codex 聊天。")
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                }
            }
        }
    }

    private var antigravitySteps: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                state(
                    "连接 MCP",
                    detail: model.antigravityConnection?.toolsAvailable == true ?
                        "Antigravity 已配置，搜索、领取和写回工具可用" :
                        model.antigravityConnection?.registered == true ?
                        "已写入配置，等待本地工具可用" :
                        model.checkingAntigravity ? "正在检查 Antigravity 配置" : "待连接或验证",
                    verified: model.antigravityConnection?.toolsAvailable == true
                )
                Spacer()
                if model.antigravityConnection?.registered != true {
                    Button("连接 Antigravity") {
                        copyState.antigravityConnectRequested = true
                        model.configureAntigravity(.connect)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.checkingAntigravity || model.store == nil)
                }
                Button("验证连接") { model.configureAntigravity() }
                    .disabled(model.checkingAntigravity || model.store == nil)
            }
            if model.antigravityConnection?.registered == true {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                        .font(.caption)
                        .foregroundStyle(copyState.antigravityConnectRequested ? theme.warning : theme.accent)
                        .padding(.top, 1)
                    Text("已成功写入 ~/.gemini/config/mcp_config.json。请彻底退出 Antigravity 客户端（⌘Q）后再重新打开，使 MCP 配置生效。")
                        .font(.caption)
                        .foregroundStyle(theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    (copyState.antigravityConnectRequested ? theme.warningSoft : theme.accentSoft),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke((copyState.antigravityConnectRequested ? theme.warning : theme.accent).opacity(0.32), lineWidth: 1)
                )
                .padding(.leading, 23)
            }
            Divider().overlay(theme.hairlineBorder)
            HStack {
                state(
                    "采集聊天",
                    detail: model.antigravityStatus.isEmpty ?
                        (model.antigravityEnabled ? "已启用，等待首次扫描" : "从启用时开始增量收录") :
                        model.antigravityStatus,
                    verified: model.antigravityEnabled && model.antigravityLastScan != nil
                )
                Spacer()
                if model.antigravityScanning { ProgressView().controlSize(.small) }
                Button(model.antigravityEnabled ? "立即扫描" : "启用采集") {
                    if model.antigravityEnabled { Task { await model.scanAntigravity(force: true) } }
                    else { model.captureAntigravity(true) }
                }
                .disabled(model.antigravityScanning || model.store == nil)
            }
            Divider().overlay(theme.hairlineBorder)
            HStack(alignment: .top) {
                state(
                    "自动检索",
                    detail: antigravityRecallStatus,
                    verified: antigravityRecallVerified
                )
                Spacer()
                if model.antigravityRecallEnabled {
                    if model.antigravityConnection?.recallInstalled == true {
                        Button(copyState.copiedVerify ? "已复制验证指令" : (antigravityRecallVerified ? "再次验证" : "复制验证指令")) {
                            model.copyAntigravityRecallTestPrompt()
                            copyState.copiedVerify = true
                        }
                    } else {
                        Button("修复 Hook 配置") { model.configureAntigravity(.enableRecall) }
                            .disabled(model.checkingAntigravity)
                    }
                    Button("关闭") { model.configureAntigravity(.disableRecall) }
                        .disabled(model.checkingAntigravity)
                        .accessibilityLabel("关闭 Antigravity 自动检索")
                } else {
                    Button("配置自动检索") { model.configureAntigravity(.enableRecall) }
                        .disabled(model.checkingAntigravity || model.antigravityConnection?.toolsAvailable != true)
                }
            }
            if let date = model.antigravityRecallVerifiedAt, antigravityRecallVerified {
                Text("最近一次验证 " + date.formatted(.dateTime.month().day().hour().minute()))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(theme.textSecondary)
                    .padding(.leading, 23)
            } else if model.antigravityRecallEnabled, model.antigravityConnection?.recallInstalled == true {
                Text("已写入 ~/.gemini/config/hooks.json（PreInvocation）。请在 Antigravity 重启或刷新 MCP Servers 后新开对话，发送验证指令「Agent Memory · 验证自动检索」。")
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
                    .padding(.leading, 23)
            }
            if let error = model.antigravitySetupError ?? model.antigravityConnection?.hookError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(theme.warning)
            }
            HStack {
                Button(copyState.copied ? "已复制配置指令" : "复制给 Antigravity 配置") {
                    model.copyAntigravitySetupInstructions()
                    copyState.copied = true
                }
                .buttonStyle(.link)
                .disabled(model.store == nil)
                if copyState.copied {
                    Text("粘贴到 Antigravity 聊天执行配置。")
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                }
            }
        }
    }

    private var antigravityRecallStatus: String {
        if antigravityRecallVerified { return "运行已验证" }
        if model.antigravityRecallEnabled, model.antigravityConnection?.recallInstalled == true {
            return "已写入 Hook 配置，待发送验证指令"
        }
        return "搜索当前项目和全局记忆，并带入高相关结果"
    }

    private var antigravityRecallVerified: Bool {
        model.antigravityRecallEnabled && model.antigravityConnection?.recallInstalled == true && model.antigravityRecallVerifiedAt != nil
    }

    private var recallStatus: String {
        if recallVerified { return "运行已验证" }
        if model.recallEnabled {
            switch model.connection?.hookStatus {
            case "unavailable": return "配置已写入，Codex 暂未加载此 Hook"
            case "disabled": return "Hook 已在 Codex 停用"
            case "untrusted", "modified": return "待在 Codex 审核 Hook"
            default: break
            }
        }
        if model.recallEnabled, model.connection?.recallInstalled == true {
            return model.connection?.hookStatus == "trusted" ? "Codex 已授权，待发送验证指令" : "已写入配置，待发送验证指令"
        }
        return "搜索当前项目和全局记忆，并带入高相关结果"
    }

    private var recallVerified: Bool {
        model.recallEnabled && model.connection?.recallInstalled == true && model.recallVerifiedAt != nil
    }

    private func state(_ title: String, detail: String, verified: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: verified ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(verified ? theme.success : theme.textTertiary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(theme.textPrimary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(theme.textSecondary)
            }
        }
    }
}
