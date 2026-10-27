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
        LocalBridgeService.shared.startIfNeeded()
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
        #if DEBUG
        writeE2EPairingIfRequested()
        #endif

        let needsOnboarding = !PermissionManager.shared.isAccessibilityGranted
            || !BotManager.shared.isConfigured

        if needsOnboarding {
            showOnboarding()
        } else {
            FeishuClient.shared.connectWithStoredCredentials()
        }
    }

    #if DEBUG
    /// 端到端测试用：`--e2e-pair <path>` 换一台名为 E2E 的设备，把配对二维码内容写到 path；
    /// `--e2e-unpair` 只吊销 E2E 设备（脚本收尾用）
    private func writeE2EPairingIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        let service = LocalBridgeService.shared
        if args.contains("--e2e-unpair") {
            service.devices.filter { $0.name == "E2E" }.forEach(service.revoke)
            return
        }
        guard let index = args.firstIndex(of: "--e2e-pair"), index + 1 < args.count else { return }
        let path = args[index + 1]
        Task { @MainActor in
            service.devices.filter { $0.name == "E2E" }.forEach(service.revoke)
            guard let payload = await service.addDevice(name: "E2E") else { return }
            try? payload.url.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
    #endif

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
