import SwiftUI

@MainActor
final class LocalState<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}

enum RuntimeStatusKind {
    case active
    case indexing
    case idle
    case paused
    case error

    func color(in theme: ThemePalette) -> Color {
        switch self {
        case .active: return theme.success
        case .indexing: return theme.info
        case .idle: return theme.accent
        case .paused: return theme.textTertiary
        case .error: return theme.danger
        }
    }

    func softColor(in theme: ThemePalette) -> Color {
        switch self {
        case .active: return theme.successSoft
        case .indexing: return theme.infoSoft
        case .idle: return theme.accentSoft
        case .paused: return theme.surfaceSecondary
        case .error: return theme.dangerSoft
        }
    }
}

struct StatusCapsule: View {
    @Environment(\.theme) private var theme
    let title: String
    let kind: RuntimeStatusKind
    var showSpinner: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            if showSpinner {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.75)
            } else {
                Circle()
                    .fill(kind.color(in: theme))
                    .frame(width: 7, height: 7)
                    .shadow(color: kind.color(in: theme).opacity(theme.isDark ? 0.65 : 0.3), radius: 3)
            }
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(kind == .paused ? theme.textSecondary : kind.color(in: theme))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(kind.softColor(in: theme), in: Capsule())
        .overlay(
            Capsule().stroke(kind.color(in: theme).opacity(kind == .paused ? 0.18 : 0.30), lineWidth: 1)
        )
    }
}

enum AgentBrand: String, CaseIterable, Identifiable {
    case codex = "Codex"
    case antigravity = "Antigravity"

    var id: Self { self }

    var icon: String {
        switch self {
        case .codex: return "terminal"
        case .antigravity: return "sparkles"
        }
    }

    func color(in theme: ThemePalette) -> Color {
        switch self {
        case .codex: return theme.agentCodex
        case .antigravity: return theme.agentAntigravity
        }
    }

    func softColor(in theme: ThemePalette) -> Color {
        switch self {
        case .codex: return theme.agentCodexSoft
        case .antigravity: return theme.agentAntigravitySoft
        }
    }
}

struct AgentTag: View {
    @Environment(\.theme) private var theme
    let agent: AgentBrand
    var active: Bool = true

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(active ? agent.color(in: theme) : theme.textTertiary)
                .frame(width: 6, height: 6)
            Text(agent.rawValue)
                .font(.caption.weight(.medium))
                .foregroundStyle(active ? agent.color(in: theme) : theme.textSecondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(active ? agent.softColor(in: theme) : theme.surfaceSecondary, in: Capsule())
        .overlay(
            Capsule().stroke((active ? agent.color(in: theme) : theme.hairlineBorder).opacity(0.28), lineWidth: 1)
        )
    }
}

struct ScopeTag: View {
    @Environment(\.theme) private var theme
    let projectPath: String?

    private var isGlobal: Bool { projectPath == nil || projectPath?.isEmpty == true }

    private var label: String {
        guard let projectPath, !projectPath.isEmpty else { return "全局" }
        return URL(fileURLWithPath: projectPath).lastPathComponent
    }

    var body: some View {
        let fg = isGlobal ? theme.scopeGlobal : theme.scopeProject
        let bg = isGlobal ? theme.scopeGlobalSoft : theme.scopeProjectSoft
        HStack(spacing: 4) {
            Image(systemName: isGlobal ? "globe" : "folder")
                .font(.system(size: 10, weight: .semibold))
            Text(label)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(bg, in: Capsule())
        .overlay(Capsule().stroke(fg.opacity(0.22), lineWidth: 1))
        .help(projectPath ?? "全局作用域")
    }
}

struct ScorePill: View {
    @Environment(\.theme) private var theme
    let label: String
    let value: String
    var tint: Color? = nil

    var body: some View {
        let color = tint ?? theme.textSecondary
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(theme.textTertiary)
            Text(value)
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(theme.surfaceSecondary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(theme.hairlineBorder, lineWidth: 1)
        )
    }
}

struct KPIMetricCard: View {
    @Environment(\.theme) private var theme
    let title: String
    let value: String
    var subtitle: String? = nil
    let icon: String
    var tint: Color? = nil
    var action: (() -> Void)? = nil

    @StateObject private var hovered = LocalState(false)

    var body: some View {
        let accent = tint ?? theme.accent
        let isHovered = hovered.value
        let card = VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 26, height: 26)
                    .background(accent.opacity(theme.isDark ? 0.16 : 0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                if action != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(isHovered ? accent : theme.textTertiary)
                }
            }
            Text(value)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
        .background(theme.surfacePrimary, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(isHovered && action != nil ? accent.opacity(0.42) : theme.hairlineBorder, lineWidth: 1)
        )
        .shadow(color: theme.cardShadow, radius: isHovered ? 10 : 5, y: isHovered ? 4 : 2)
        .onHover { hovered.value = $0 }

        if let action {
            Button(action: action) { card }
                .buttonStyle(.plain)
        } else {
            card
        }
    }
}

struct SectionHeader<Trailing: View>: View {
    @Environment(\.theme) private var theme
    let title: String
    var count: Int? = nil
    @ViewBuilder let trailing: () -> Trailing

    init(_ title: String, count: Int? = nil, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.count = count
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(theme.textPrimary)
            if let count {
                Text("\(count)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(theme.surfaceSecondary, in: Capsule())
                    .overlay(Capsule().stroke(theme.hairlineBorder, lineWidth: 1))
            }
            Spacer()
            trailing()
        }
    }
}

struct ErrorBanner: View {
    @Environment(\.theme) private var theme
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(theme.warning)
            Text(message)
                .font(.callout)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(2)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭错误提示")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(theme.warningSoft)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.warning.opacity(0.28)).frame(height: 1)
        }
    }
}

struct EmptyStateCard: View {
    @Environment(\.theme) private var theme
    let icon: String
    let title: String
    let description: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(theme.accent)
                .frame(width: 52, height: 52)
                .background(theme.accentSoft, in: Circle())
            VStack(spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(theme.textPrimary)
                Text(description)
                    .font(.callout)
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .padding(24)
        .background(theme.surfacePrimary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(theme.hairlineBorder, lineWidth: 1)
        )
    }
}

struct CopyToastBanner: View {
    @Environment(\.theme) private var theme
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(theme.accent)
                .font(.title3)
            Text(message)
                .font(.callout.weight(.medium))
                .foregroundStyle(theme.textPrimary)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭提示")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(theme.accentBorder, lineWidth: 1)
        )
        .shadow(color: theme.cardShadow, radius: 14, y: 6)
    }
}
