import SwiftUI

struct MenuBarView: View {

    @State private var feishu = FeishuClient.shared
    @State private var localBridge = LocalBridgeService.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // 状态 (将原本的视图包装为 Button，防止系统将其渲染为灰色的禁用状态)
        Button(action: {
            // 提供重新连接的便捷入口
            if case .disconnected = feishu.state {
                FeishuClient.shared.connectWithStoredCredentials()
            }
        }) {
            // 全面拥抱原生底层：使用自带固定色彩的 Emoji 解决系统对图像的强行去色模板化机制
            statusView
        }
        .onAppear {
            let needsOnboarding = !PermissionManager.shared.isAccessibilityGranted
                || !BotManager.shared.isConfigured
            if needsOnboarding {
                (NSApp.delegate as? AppDelegate)?.showOnboarding()
            }
        }

        // 手机直连
        if !localBridge.devices.isEmpty {
            Divider()
            Text(localBridgeStatusText)
            ForEach(localBridge.peers) { peer in
                Text("    📱 \(peer.deviceName ?? peer.deviceId)")
            }
        }

        Divider()

        // 设置
        Button("设置...") {
            openSettings()
            // 菜单栏应用无 Dock 图标，需显式激活才能将已打开的设置窗口置顶
            // async 延迟到下一轮 RunLoop，确保 openSettings() 创建的窗口已就位
            DispatchQueue.main.async {
                NSApp.activate()
            }
        }
        .keyboardShortcut(",", modifiers: .command)

        // 退出
        Button("退出 VoiceBridge") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    // MARK: - 状态

    private var localBridgeStatusText: String {
        switch localBridge.state {
        case .stopped: return "手机直连：未启动"
        case .starting: return "手机直连：启动中..."
        case .listening: return localBridge.peers.isEmpty ? "手机直连：等待设备" : "手机直连：\(localBridge.peers.count) 台已连接"
        case .failed(let message): return "手机直连：失败（\(message)）"
        }
    }

    private var statusView: Text {
        // 适当缩小 Emoji 的尺寸，并略微上移对齐中线，使其更像一个精致的小圆点
        let dotSize: CGFloat = 10
        let offset: CGFloat = 0.5
        
        switch feishu.state {
        case .disconnected:
            return Text("\(Text("⚪️").font(.system(size: dotSize)).baselineOffset(offset)) 未连接")
        case .connecting:
            return Text("\(Text("🟠").font(.system(size: dotSize)).baselineOffset(offset)) 连接中...")
        case .connected:
            return Text("\(Text("🟢").font(.system(size: dotSize)).baselineOffset(offset)) 已连接")
        case .reconnecting(let attempt):
            return Text("\(Text("🟠").font(.system(size: dotSize)).baselineOffset(offset)) 重连中 (\(attempt))...")
        }
    }
}
