import AppKit
import Combine
import SwiftUI

extension AppThemeMode {
    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .dark: return "深色"
        case .light: return "浅色"
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .dark: return "moon.fill"
        case .light: return "sun.max.fill"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .dark: return NSAppearance(named: .darkAqua)
        case .light: return NSAppearance(named: .aqua)
        }
    }

    var next: AppThemeMode {
        switch self {
        case .system: return .dark
        case .dark: return .light
        case .light: return .system
        }
    }
}

@MainActor
final class AppAppearanceCoordinator: ObservableObject {
    static let shared = AppAppearanceCoordinator()

    @Published private(set) var resolvedColorScheme: ColorScheme
    private var mode: AppThemeMode = .system
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        resolvedColorScheme = Self.resolveSystemColorScheme()

        // Observe live macOS system appearance changes when in `.system` mode.
        DistributedNotificationCenter.default()
            .publisher(for: Notification.Name("AppleInterfaceThemeChangedNotification"))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshResolvedScheme()
            }
            .store(in: &cancellables)

        if let app = NSApp {
            app.publisher(for: \.effectiveAppearance, options: [.new])
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    self?.refreshResolvedScheme()
                }
                .store(in: &cancellables)
        }
    }

    func apply(_ newMode: AppThemeMode) {
        mode = newMode
        let targetAppearance = newMode.nsAppearance
        if let app = NSApp {
            if app.appearance?.name != targetAppearance?.name {
                app.appearance = targetAppearance
            }
            for window in app.windows {
                if window.appearance?.name != targetAppearance?.name {
                    window.appearance = targetAppearance
                }
            }
        }
        refreshResolvedScheme()
    }

    private func refreshResolvedScheme() {
        let next: ColorScheme
        switch mode {
        case .dark:
            next = .dark
        case .light:
            next = .light
        case .system:
            next = Self.resolveSystemColorScheme()
        }
        if resolvedColorScheme != next {
            resolvedColorScheme = next
        }
    }

    private static func resolveSystemColorScheme() -> ColorScheme {
        if let app = NSApp, app.appearance == nil {
            let match = app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
            return match == .darkAqua ? .dark : .light
        }
        if let style = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") {
            return style.caseInsensitiveCompare("Dark") == .orderedSame ? .dark : .light
        }
        return .light
    }
}

struct ThemePalette: Equatable {
    let colorScheme: ColorScheme

    var isDark: Bool { colorScheme == .dark }

    // MARK: - Background & Surface Hierarchy

    var canvasBackground: Color {
        isDark
            ? Color(red: 9 / 255, green: 11 / 255, blue: 16 / 255)
            : Color(red: 245 / 255, green: 247 / 255, blue: 250 / 255)
    }

    var surfacePrimary: Color {
        isDark
            ? Color(red: 14 / 255, green: 17 / 255, blue: 23 / 255)
            : Color(red: 255 / 255, green: 255 / 255, blue: 255 / 255)
    }

    var surfaceSecondary: Color {
        isDark
            ? Color(red: 20 / 255, green: 25 / 255, blue: 34 / 255)
            : Color(red: 248 / 255, green: 250 / 255, blue: 252 / 255)
    }

    var surfaceElevated: Color {
        isDark
            ? Color(red: 25 / 255, green: 31 / 255, blue: 42 / 255)
            : Color(red: 255 / 255, green: 255 / 255, blue: 255 / 255)
    }

    var inspectorBackground: Color {
        isDark
            ? Color(red: 12 / 255, green: 15 / 255, blue: 21 / 255)
            : Color(red: 250 / 255, green: 251 / 255, blue: 253 / 255)
    }

    // MARK: - Borders

    var hairlineBorder: Color {
        isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
    }

    var strongBorder: Color {
        isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.14)
    }

    var accentBorder: Color {
        accent.opacity(isDark ? 0.42 : 0.36)
    }

    // MARK: - Text

    var textPrimary: Color {
        isDark
            ? Color(red: 240 / 255, green: 244 / 255, blue: 249 / 255)
            : Color(red: 15 / 255, green: 23 / 255, blue: 42 / 255)
    }

    var textSecondary: Color {
        isDark
            ? Color(red: 148 / 255, green: 163 / 255, blue: 184 / 255)
            : Color(red: 71 / 255, green: 85 / 255, blue: 105 / 255)
    }

    var textTertiary: Color {
        isDark
            ? Color(red: 100 / 255, green: 116 / 255, blue: 139 / 255)
            : Color(red: 148 / 255, green: 163 / 255, blue: 184 / 255)
    }

    // MARK: - Brand & Semantic Accent

    var accent: Color {
        isDark
            ? Color(red: 92 / 255, green: 225 / 255, blue: 204 / 255)
            : Color(red: 13 / 255, green: 148 / 255, blue: 136 / 255)
    }

    var accentSoft: Color {
        accent.opacity(isDark ? 0.14 : 0.11)
    }

    var success: Color {
        isDark
            ? Color(red: 52 / 255, green: 211 / 255, blue: 153 / 255)
            : Color(red: 5 / 255, green: 150 / 255, blue: 105 / 255)
    }

    var successSoft: Color {
        success.opacity(isDark ? 0.15 : 0.11)
    }

    var warning: Color {
        isDark
            ? Color(red: 251 / 255, green: 191 / 255, blue: 36 / 255)
            : Color(red: 217 / 255, green: 119 / 255, blue: 6 / 255)
    }

    var warningSoft: Color {
        warning.opacity(isDark ? 0.15 : 0.12)
    }

    var danger: Color {
        isDark
            ? Color(red: 248 / 255, green: 113 / 255, blue: 113 / 255)
            : Color(red: 220 / 255, green: 38 / 255, blue: 38 / 255)
    }

    var dangerSoft: Color {
        danger.opacity(isDark ? 0.15 : 0.11)
    }

    var info: Color {
        isDark
            ? Color(red: 96 / 255, green: 165 / 255, blue: 250 / 255)
            : Color(red: 37 / 255, green: 99 / 255, blue: 235 / 255)
    }

    var infoSoft: Color {
        info.opacity(isDark ? 0.15 : 0.11)
    }

    // MARK: - Scope & Agent Semantics

    var scopeGlobal: Color {
        isDark
            ? Color(red: 167 / 255, green: 139 / 255, blue: 250 / 255)
            : Color(red: 109 / 255, green: 40 / 255, blue: 217 / 255)
    }

    var scopeGlobalSoft: Color {
        scopeGlobal.opacity(isDark ? 0.16 : 0.10)
    }

    var scopeProject: Color { accent }
    var scopeProjectSoft: Color { accentSoft }

    var agentCodex: Color {
        isDark
            ? Color(red: 92 / 255, green: 225 / 255, blue: 204 / 255)
            : Color(red: 13 / 255, green: 148 / 255, blue: 136 / 255)
    }

    var agentCodexSoft: Color {
        agentCodex.opacity(isDark ? 0.15 : 0.11)
    }

    var agentAntigravity: Color {
        isDark
            ? Color(red: 129 / 255, green: 140 / 255, blue: 248 / 255)
            : Color(red: 79 / 255, green: 70 / 255, blue: 229 / 255)
    }

    var agentAntigravitySoft: Color {
        agentAntigravity.opacity(isDark ? 0.16 : 0.11)
    }

    // MARK: - Memory Galaxy Canvas Palette (Wave 3 ready)

    var galaxyBackground: Color {
        isDark
            ? Color(red: 8 / 255, green: 10 / 255, blue: 16 / 255)
            : Color(red: 241 / 255, green: 245 / 255, blue: 249 / 255)
    }

    var galaxyGrid: Color {
        isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.05)
    }

    var galaxyEdge: Color {
        isDark ? Color.white.opacity(0.16) : Color.black.opacity(0.15)
    }

    // MARK: - Shadows

    var cardShadow: Color {
        isDark ? Color.black.opacity(0.35) : Color.black.opacity(0.06)
    }
}

private struct ThemePaletteKey: EnvironmentKey {
    static let defaultValue = ThemePalette(colorScheme: .dark)
}

extension EnvironmentValues {
    var theme: ThemePalette {
        get { self[ThemePaletteKey.self] }
        set { self[ThemePaletteKey.self] = newValue }
    }
}

private struct ThemeRootModifier: ViewModifier {
    let mode: AppThemeMode
    @ObservedObject private var coordinator = AppAppearanceCoordinator.shared

    func body(content: Content) -> some View {
        let resolvedScheme = coordinator.resolvedColorScheme
        let palette = ThemePalette(colorScheme: resolvedScheme)
        content
            .environment(\.theme, palette)
            .environment(\.colorScheme, resolvedScheme)
            .preferredColorScheme(resolvedScheme)
            .tint(palette.accent)
            .onAppear {
                coordinator.apply(mode)
            }
            .onChange(of: mode) { _, newMode in
                coordinator.apply(newMode)
            }
    }
}

extension View {
    func applyTheme(_ mode: AppThemeMode) -> some View {
        modifier(ThemeRootModifier(mode: mode))
    }

    func surfaceCard(cornerRadius: CGFloat = 12, padding: CGFloat = 14, highlighted: Bool = false) -> some View {
        modifier(SurfaceCardModifier(cornerRadius: cornerRadius, padding: padding, highlighted: highlighted))
    }
}

private struct SurfaceCardModifier: ViewModifier {
    @Environment(\.theme) private var theme
    let cornerRadius: CGFloat
    let padding: CGFloat
    let highlighted: Bool

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                highlighted ? theme.accentSoft : theme.surfacePrimary,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(highlighted ? theme.accentBorder : theme.hairlineBorder, lineWidth: 1)
            )
            .shadow(color: theme.cardShadow, radius: theme.isDark ? 6 : 4, y: 2)
    }
}
