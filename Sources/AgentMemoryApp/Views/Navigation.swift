import AgentMemoryCore
import AppKit
import SwiftUI

enum AppPage: String, CaseIterable, Identifiable {
    case overview = "概览"
    case memory = "记忆"
    case dream = "做梦"
    case activity = "活动"
    case settings = "设置"

    var id: Self { self }

    var icon: String {
        switch self {
        case .overview: return "circle.hexagongrid"
        case .memory: return "brain.head.profile"
        case .dream: return "moon.stars"
        case .activity: return "waveform.path.ecg"
        case .settings: return "gearshape"
        }
    }

    @MainActor
    func badgeCount(in model: AppModel) -> Int {
        guard let dashboard = model.dashboard else { return 0 }
        switch self {
        case .dream:
            return dashboard.pending + dashboard.review
        default:
            return 0
        }
    }
}

extension RuntimeHealth.CaptureState {
    func presentation(smartCapture: Bool) -> (title: String, kind: RuntimeStatusKind, spinning: Bool) {
        switch self {
        case .scanning:
            return ("采集中", .active, true)
        case .idle:
            return (smartCapture ? "智能监听" : "运行中", .idle, false)
        case .paused:
            return ("已暂停", .paused, false)
        case .failed:
            return ("采集异常", .error, false)
        case .unavailable:
            return ("不可用", .paused, false)
        }
    }
}

extension RuntimeHealth.EmbeddingState {
    var presentation: (title: String, detail: String, kind: RuntimeStatusKind, spinning: Bool) {
        switch self {
        case .checking:
            return ("检查中", "正在检查本地向量引擎", .indexing, true)
        case .indexing:
            return ("索引中", "正在更新本地语义向量索引", .indexing, true)
        case .ready:
            return ("已就绪", "混合向量检索就绪", .active, false)
        case .unavailable:
            return ("降级中", "向量未就绪 · 使用关键词检索", .paused, false)
        case .failed:
            return ("索引异常", "本地向量索引失败 · 已降级关键词", .error, false)
        }
    }
}

extension ActivityEvent.Agent {
    var brand: AgentBrand {
        switch self {
        case .codex: return .codex
        case .antigravity: return .antigravity
        }
    }
}

extension AppModel {
    var isAnySourceEnabled: Bool {
        enabled || antigravityEnabled
    }

    var isAnyScanning: Bool {
        runtimeHealth.codexCapture == .scanning || runtimeHealth.antigravityCapture == .scanning
    }

    var overallRuntimeStatus: (title: String, kind: RuntimeStatusKind, spinning: Bool) {
        if error != nil || store == nil ||
            runtimeHealth.codexCapture == .failed ||
            runtimeHealth.antigravityCapture == .failed ||
            runtimeHealth.embedding == .failed {
            return ("运行异常", .error, false)
        }
        if isAnyScanning {
            return ("采集中", .active, true)
        }
        if runtimeHealth.embedding == .indexing {
            return ("索引中", .indexing, true)
        }
        if runtimeHealth.embedding == .checking {
            return ("检查中", .indexing, true)
        }
        if runtimeHealth.codexCapture == .idle || runtimeHealth.antigravityCapture == .idle {
            return (smartCapture ? "智能监听中" : "轮询采集中", .idle, false)
        }
        return ("采集已暂停", .paused, false)
    }

    var activeSourceNames: [String] {
        [enabled ? "Codex" : nil, antigravityEnabled ? "Antigravity" : nil].compactMap { $0 }
    }

    func scanAllEnabled(force: Bool = true) async {
        async let codexScan: Void = enabled ? scan(force: force) : ()
        async let agyScan: Void = antigravityEnabled ? scanAntigravity(force: force) : ()
        _ = await (codexScan, agyScan)
    }
}

struct WindowCloseInterceptor: NSViewRepresentable {
    let model: AppModel
    let appDelegate: AppLifecycleDelegate

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { attach(to: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { attach(to: nsView.window) }
    }

    @MainActor
    private func attach(to window: NSWindow?) {
        guard let window else { return }
        window.titlebarSeparatorStyle = .none
        appDelegate.mainWindow = window
        if let existing = window.delegate as? WindowCloseDelegateProxy {
            existing.model = model
            return
        }
        let proxy = WindowCloseDelegateProxy(model: model, originalDelegate: window.delegate)
        objc_setAssociatedObject(window, &WindowCloseDelegateProxy.associationKey, proxy, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        window.delegate = proxy
    }
}

private final class WindowCloseDelegateProxy: NSObject, NSWindowDelegate {
    static var associationKey: UInt8 = 0
    weak var model: AppModel?
    weak var originalDelegate: NSWindowDelegate?

    init(model: AppModel, originalDelegate: NSWindowDelegate?) {
        self.model = model
        self.originalDelegate = originalDelegate
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if aSelector == #selector(NSWindowDelegate.windowShouldClose(_:)) {
            return true
        }
        if super.responds(to: aSelector) { return true }
        return originalDelegate?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let originalDelegate, originalDelegate.responds(to: aSelector) {
            return originalDelegate
        }
        return super.forwardingTarget(for: aSelector)
    }

    @MainActor
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let model else {
            return originalDelegate?.windowShouldClose?(sender) ?? true
        }
        switch model.closeBehavior {
        case .minimizeToMenuBar:
            return originalDelegate?.windowShouldClose?(sender) ?? true
        case .quit:
            NSApp.terminate(nil)
            return false
        case .ask:
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "关闭 Agent Memory 窗口？"
            alert.informativeText = "选择「保留在状态栏」将继续在后台采集聊天并提供 MCP 服务；选择「彻底退出」将完全关闭程序。你随时可以在「设置」中修改此行为。"
            alert.addButton(withTitle: "保留在状态栏")
            alert.addButton(withTitle: "彻底退出")
            alert.addButton(withTitle: "取消")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "记住我的选择，不再询问"

            let response = alert.runModal()
            let remember = alert.suppressionButton?.state == .on
            switch response {
            case .alertFirstButtonReturn:
                if remember { model.setCloseBehavior(.minimizeToMenuBar) }
                return originalDelegate?.windowShouldClose?(sender) ?? true
            case .alertSecondButtonReturn:
                if remember { model.setCloseBehavior(.quit) }
                NSApp.terminate(nil)
                return false
            default:
                return false
            }
        }
    }
}
