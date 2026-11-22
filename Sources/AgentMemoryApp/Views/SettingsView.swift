import SwiftUI

struct SettingsView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var model: AppModel
    @Binding var showBackfill: Bool
    @Binding var selectedAgent: AgentBrand

    var body: some View {
        Form {
            Section("Agent 连接与自动检索引导") {
                AgentSetupView(model: model, selectedAgent: $selectedAgent)
            }

            Section("外观主题") {
                HStack {
                    Text("主题模式")
                        .foregroundStyle(theme.textPrimary)
                    Spacer()
                    SegmentedPillBar(
                        options: AppThemeMode.allCases,
                        selection: $model.themeMode,
                        label: { $0.label },
                        icon: { $0.icon },
                        compact: true
                    )
                }
                Text("支持跟随 macOS 系统外观自动切换，或手动锁定深色 / 浅色模式。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("自动检索") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(
                        "跨项目自动注入记忆",
                        isOn: Binding(get: { model.recallCrossProject }, set: { model.setRecallCrossProject($0) })
                    )
                    Text("开启后，对话前 Hook 自动注入将检索全部项目的记忆；关闭（默认）时仅检索当前工作区及全局记忆，避免其他项目内容干扰。即使关闭，Agent 仍可按需主动调用 memory_search 跨项目查询。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("性能与省电") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(
                        "智能采集（省电模式）",
                        isOn: Binding(get: { model.smartCapture }, set: { model.setSmartCapture($0) })
                    )
                    Text("默认开启。通过系统文件监听在聊天产生变化时按需采集，空闲 5 分钟后自动休眠本地向量进程以降低 CPU 与内存占用。关闭后将回退为每 30 秒定时轮询兜底。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("采集来源") {
                Toggle("全局采集 Codex 聊天", isOn: Binding(get: { model.enabled }, set: { model.capture($0) }))
                Toggle("全局采集 Antigravity 聊天", isOn: Binding(get: { model.antigravityEnabled }, set: { model.captureAntigravity($0) }))
                Button("选择日期回填 Codex 聊天…") { showBackfill = true }
                    .buttonStyle(SoftActionButtonStyle(compact: true))
            }

            Section("启动与关闭") {
                Toggle("登录时打开", isOn: Binding(get: { model.login }, set: model.loginSetting))
                Picker("点击关闭按钮时", selection: Binding(get: { model.closeBehavior }, set: { model.setCloseBehavior($0) })) {
                    ForEach(CloseBehavior.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
            }

            Section("检索与引擎") {
                LabeledContent("本地向量", value: model.runtimeHealth.embedding.presentation.detail)
            }

            if !model.excludedProjects.isEmpty || !model.excludedThreads.isEmpty {
                Section("排除项") {
                    ForEach(model.excludedProjects, id: \.self) { value in
                        LabeledContent(value) {
                            Button("取消排除") { model.removeExclusion(value, byProject: true) }
                                .buttonStyle(SoftActionButtonStyle(compact: true))
                        }
                    }
                    ForEach(model.excludedThreads, id: \.self) { value in
                        LabeledContent(value) {
                            Button("取消排除") { model.removeExclusion(value, byProject: false) }
                                .buttonStyle(SoftActionButtonStyle(compact: true))
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
    }
}
