import SwiftUI

@main
struct VoiceBridgeApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var feishu = FeishuClient.shared

    init() {
        FeishuClient.shared.onTextReceived = { text in
            DispatchQueue.main.async {
                TextInjector.shared.inject(text)
            }
        }
        FeishuClient.shared.onEnterReceived = {
            DispatchQueue.main.async {
                TextInjector.shared.pressEnter()
            }
        }
        FeishuClient.shared.onClearReceived = {
            DispatchQueue.main.async {
                TextInjector.shared.clear()
            }
        }
        FeishuClient.shared.onShiftEnterReceived = {
            DispatchQueue.main.async {
                TextInjector.shared.pressShiftEnter()
            }
        }
    }

    var body: some Scene {
        MenuBarExtra("VoiceBridge", systemImage: menuBarIcon) {
            MenuBarView()
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
        }
    }

    private var menuBarIcon: String {
        switch feishu.state {
        case .connected: return "mic.fill"
        case .connecting, .reconnecting: return "mic.and.signal.meter"
        case .disconnected: return "mic.slash"
        }
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let needsOnboarding = !PermissionManager.shared.isAccessibilityGranted
            || !BotManager.shared.isConfigured

        if needsOnboarding {
            showOnboarding()
        } else {
            FeishuClient.shared.connectWithStoredCredentials()
        }
    }

    func showOnboarding() {
        // Prevent duplicate windows
        if onboardingWindow != nil { return }

        let onboardingView = OnboardingView { [weak self] in
            self?.onboardingWindow?.close()
            self?.onboardingWindow = nil
            FeishuClient.shared.connectWithStoredCredentials()
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: onboardingView)
        window.title = "VoiceBridge 设置向导"
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        self.onboardingWindow = window
    }
}
