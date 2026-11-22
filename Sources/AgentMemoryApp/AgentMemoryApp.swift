import AppKit
import SwiftUI

final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    var openMainWindow: (() -> Void)?
    weak var mainWindow: NSWindow?

    @MainActor
    func reopenMainWindow() {
        if let existing = mainWindow, existing.isVisible || existing.isMiniaturized {
            existing.titlebarSeparatorStyle = .none
            existing.deminiaturize(nil)
            existing.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in
            reopenMainWindow()
        }
        return false
    }
}

@main
struct AgentMemoryApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Agent Memory", id: "main") {
            MainShellView(model: model)
                .applyTheme(model.themeMode)
                .background(WindowCloseInterceptor(model: model, appDelegate: appDelegate))
                .onAppear {
                    appDelegate.openMainWindow = { openWindow(id: "main") }
                }
                .frame(minWidth: 860, minHeight: 540)
        }
        .defaultSize(width: 1160, height: 700)
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified)

        MenuBarExtra(
            "Agent Memory",
            systemImage: model.isAnySourceEnabled ? "circle.hexagongrid.fill" : "circle.hexagongrid"
        ) {
            MenuBarPanelView(model: model) {
                appDelegate.openMainWindow = { openWindow(id: "main") }
                appDelegate.reopenMainWindow()
            }
            .applyTheme(model.themeMode)
        }
        .menuBarExtraStyle(.window)
    }
}
