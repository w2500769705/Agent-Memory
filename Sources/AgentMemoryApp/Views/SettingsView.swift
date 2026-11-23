import AgentMemoryCore
import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(\.theme) private var theme
    @AppStorage(GlassOpacityPreference.key) private var glassOpacity = GlassOpacityPreference.defaultValue
    @ObservedObject var model: AppModel
    @Binding var showBackfill: Bool
    @Binding var selectedAgent: AgentBrand

    var body: some View {
        Form {
            Section("Agent 连接与自动检索引导") {
                AgentSetupView(model: model, selectedAgent: $selectedAgent)
            }

            Section("项目路径迁移 / 合并") {
                ProjectMigrationSection(model: model)
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

                HStack(spacing: 10) {
                    Slider(value: $glassOpacity, in: GlassOpacityPreference.range, step: 0.01) {
                        Text("卡片玻璃不透明度")
                    }
                    .tint(theme.accent)

                    Text(GlassOpacityPreference.clamped(glassOpacity), format: .percent.precision(.fractionLength(0)))
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(theme.textSecondary)
                        .frame(minWidth: 42, alignment: .trailing)

                    Button("恢复默认") { glassOpacity = GlassOpacityPreference.defaultValue }
                        .buttonStyle(SoftActionButtonStyle(compact: true))
                        .disabled(abs(glassOpacity - GlassOpacityPreference.defaultValue) < 0.001)
                }
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

            Section("关于 Agent Memory") {
                LabeledContent("版本") {
                    HStack(spacing: 10) {
                        Text(model.appVersionSummary)
                            .monospacedDigit()
                            .textSelection(.enabled)
                            .foregroundStyle(theme.textPrimary)
                        Button("复制版本信息") { model.copyAppVersionInfo() }
                            .buttonStyle(SoftActionButtonStyle(compact: true))
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
    }
}

private struct ProjectMigrationSection: View {
    @Environment(\.theme) private var theme
    @ObservedObject var model: AppModel

    @StateObject private var sourcePath = LocalState("")
    @StateObject private var targetPath = LocalState("")
    @StateObject private var preview = LocalState<Result<ProjectMigrationPreview, Error>?>(nil)
    @StateObject private var confirmation = LocalState<ProjectMigrationPreview?>(nil)
    @StateObject private var migrationError = LocalState<String?>(nil)

    private var source: ProjectSummary? {
        model.projectSummaries.first { $0.project == sourcePath.value }
    }

    private var target: String {
        targetPath.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : targetPath.value
    }

    private var migrationPreview: ProjectMigrationPreview? {
        guard let result = preview.value, source != nil, !target.isEmpty else { return nil }
        return try? result.get()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                Text("源项目").font(.subheadline.weight(.semibold))
                if model.projectSummaries.isEmpty {
                    Text("暂无可迁移的项目")
                        .font(.callout)
                        .foregroundStyle(theme.textSecondary)
                } else {
                    projectMenu(source.map { projectName($0.project) } ?? "选择源项目", projects: model.projectSummaries) {
                        sourcePath.value = $0
                    }
                    if let source {
                        pathText(source.project)
                        Text(projectCounts(source))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(theme.textSecondary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("目标项目").font(.subheadline.weight(.semibold))
                TextField("输入目标项目的绝对路径", text: $targetPath.value)
                    .textFieldStyle(.plain)
                    .font(.system(.callout, design: .monospaced))
                    .padding(9)
                    .background(theme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.hairlineBorder))
                    .accessibilityLabel("目标项目绝对路径")

                HStack(spacing: 8) {
                    let targets = model.projectSummaries.filter { $0.project != sourcePath.value }
                    if !targets.isEmpty {
                        projectMenu("从已有项目选择", projects: targets) { targetPath.value = $0 }
                    }
                    Button(action: chooseFolder) {
                        Label("选择文件夹…", systemImage: "folder")
                    }
                    .buttonStyle(SoftActionButtonStyle(compact: true))
                }
            }

            previewContent

            HStack(spacing: 8) {
                Button("立即迁移") { confirmation.value = migrationPreview }
                    .buttonStyle(PrimaryActionButtonStyle())
                    .disabled(migrationPreview.map { $0.claimedEvidenceCount > 0 } ?? true)

                Button {
                    guard let migrationPreview else { return }
                    model.copyProjectMigrationPrompt(from: migrationPreview.fromProject, to: migrationPreview.toProject)
                } label: {
                    Label("复制给 Agent", systemImage: "doc.on.doc")
                }
                .buttonStyle(SoftActionButtonStyle(tint: theme.accent))
                .disabled(migrationPreview == nil)
            }
        }
        .foregroundStyle(theme.textPrimary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .onReceive(model.$dashboard) { _ in refreshPreview() }
        .onChange(of: sourcePath.value) { _, _ in pathsChanged() }
        .onChange(of: targetPath.value) { _, _ in pathsChanged() }
        .alert("确认迁移项目？", isPresented: confirmationPresented, presenting: confirmation.value) { plan in
            Button("取消", role: .cancel) {}
            Button("迁移") { migrate(plan) }
        } message: { plan in
            Text("源项目\n\(plan.fromProject)\n\n目标项目\n\(plan.toProject)\n\n将迁移这些记忆和证据到目标项目。\n\(impactSummary(plan))")
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        if let plan = migrationPreview {
            VStack(alignment: .leading, spacing: 7) {
                Text("迁移影响").font(.subheadline.weight(.semibold))
                Text(impactSummary(plan))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(theme.textSecondary)
                if plan.toProject != target {
                    pathText("实际目标  \(plan.toProject)")
                }
                if plan.claimedEvidenceCount > 0 {
                    Label("有 \(plan.claimedEvidenceCount) 条证据正在做梦。请先提交或退回批次，再执行迁移。", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .surfaceCard(cornerRadius: 9, padding: 11)
        } else if case .failure(let error) = preview.value {
            migrationNotice(error.localizedDescription)
        }
        if let error = migrationError.value {
            migrationNotice(error)
        }
    }

    private var confirmationPresented: Binding<Bool> {
        Binding(get: { confirmation.value != nil }, set: { if !$0 { confirmation.value = nil } })
    }

    private func projectMenu(_ title: String, projects: [ProjectSummary], select: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(projects, id: \.project) { project in
                Button {
                    select(project.project)
                } label: {
                    Text("\(projectName(project.project)) · \(project.project) · \(projectCounts(project))")
                        .monospacedDigit()
                }
            }
        } label: {
            Label(title, systemImage: "folder")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .background(theme.accent.opacity(theme.isDark ? 0.13 : 0.09), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(theme.accent.opacity(0.32), lineWidth: 1)
        )
    }

    private func projectName(_ path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    private func projectCounts(_ project: ProjectSummary) -> String {
        "活跃 \(project.activeMemoryCount) · 归档 \(project.archivedMemoryCount) · 待做梦 \(project.queuedEvidenceCount) · 做梦中 \(project.claimedEvidenceCount)"
    }

    private func impactSummary(_ plan: ProjectMigrationPreview) -> String {
        "活跃记忆 \(plan.activeMemoryCount) · 已归档 \(plan.archivedMemoryCount)\n待做梦证据 \(plan.queuedEvidenceCount) · 已完成证据 \(plan.doneEvidenceCount)"
    }

    private func pathText(_ path: String) -> some View {
        Text(path)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private func migrationNotice(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(.callout)
            .foregroundStyle(theme.danger)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择目标文件夹"
        if panel.runModal() == .OK, let url = panel.url {
            targetPath.value = url.path
        }
    }

    private func pathsChanged() {
        migrationError.value = nil
        refreshPreview()
    }

    private func refreshPreview() {
        guard !sourcePath.value.isEmpty, !target.isEmpty else {
            preview.value = nil
            return
        }
        preview.value = Result { try model.previewProjectMigration(from: sourcePath.value, to: target) }
    }

    private func migrate(_ plan: ProjectMigrationPreview) {
        do {
            try model.migrateProject(from: plan.fromProject, to: plan.toProject)
            sourcePath.value = ""
            targetPath.value = ""
        } catch {
            migrationError.value = error.localizedDescription
            refreshPreview()
        }
    }
}
