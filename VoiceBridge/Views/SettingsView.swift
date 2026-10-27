import SwiftUI
import ServiceManagement

struct SettingsView: View {

    @State private var botManager = BotManager.shared
    @State private var permissions = PermissionManager.shared
    @State private var feishu = FeishuClient.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var expandedBotId: UUID?
    @State private var showingAddBot = false
    @State private var localBridge = LocalBridgeService.shared
    @State private var showingAddDevice = false

    var body: some View {
        Form {
            // 机器人管理
            Section {
                ForEach(botManager.bots) { bot in
                    botRow(bot)
                }

                Button {
                    showingAddBot = true
                } label: {
                    HStack {
                        Image(systemName: "plus.circle")
                        Text("添加机器人")
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            } header: {
                Text("机器人")
            }

            // 手机直连
            Section {
                ForEach(localBridge.devices) { device in
                    deviceRow(device)
                }

                Button {
                    showingAddDevice = true
                } label: {
                    HStack {
                        Image(systemName: "plus.circle")
                        Text("添加设备")
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            } header: {
                Text("手机直连（AIInput）")
            } footer: {
                Text(localBridgeStatusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // 权限
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("辅助功能权限")
                        Text("用于检测焦点位置并插入文本")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    if permissions.isAccessibilityGranted {
                        Text("已授权")
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(Color.green.opacity(0.15))
                            .foregroundColor(.green)
                            .clipShape(Capsule())
                    } else {
                        HStack(spacing: 8) {
                            Text("未授权")
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 3)
                                .background(Color.red.opacity(0.15))
                                .foregroundColor(.red)
                                .clipShape(Capsule())
                            Button("去授权") {
                                permissions.requestAccessibility()
                            }
                            .controlSize(.small)
                        }
                    }
                }
            } header: {
                Text("权限")
            }

            // 通用
            Section {
                Toggle("开机自动启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = !newValue
                        }
                    }
            } header: {
                Text("通用")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .frame(minHeight: 300)
        .sheet(isPresented: $showingAddBot) {
            AddBotSheet()
        }
        .sheet(isPresented: $showingAddDevice) {
            AddDeviceSheet()
        }
        .onAppear {
            NSApp.activate()
            permissions.refreshStatus()
        }
    }

    // MARK: - 机器人行

    @ViewBuilder
    private func botRow(_ bot: BotConfiguration) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(bot.name)
                        .font(.body)
                    Text("\(channelName(bot.channel)) · \(botStatusText(bot))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { bot.isEnabled },
                    set: { newValue in
                        botManager.toggleBot(bot, enabled: newValue)
                        if newValue {
                            connectBot(bot)
                        } else {
                            feishu.disconnect()
                        }
                    }
                ))
                .labelsHidden()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation {
                    expandedBotId = expandedBotId == bot.id ? nil : bot.id
                }
            }

            // 展开详情
            if expandedBotId == bot.id {
                VStack(spacing: 8) {
                    Divider()
                    detailRow(label: "App ID", value: String(bot.appId.prefix(16)) + "...")
                    detailRow(label: "渠道", value: channelName(bot.channel))
                    detailRow(label: "状态", value: botStatusText(bot))

                    HStack {
                        Spacer()
                        Button("删除", role: .destructive) {
                            if bot.isEnabled { feishu.disconnect() }
                            botManager.removeBot(bot)
                            expandedBotId = nil
                        }
                        .controlSize(.small)
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    // MARK: - 设备行

    private func deviceRow(_ device: PairedDevice) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                Text(deviceStatusText(device))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("吊销", role: .destructive) {
                localBridge.revoke(device)
            }
            .controlSize(.small)
        }
    }

    private func deviceStatusText(_ device: PairedDevice) -> String {
        if localBridge.isConnected(device) { return "已连接" }
        guard let lastSeen = device.lastSeenAt else { return "等待首次连接" }
        return "上次连接 " + lastSeen.formatted(date: .abbreviated, time: .shortened)
    }

    private var localBridgeStatusText: String {
        switch localBridge.state {
        case .stopped: return "未配对设备时不监听"
        case .starting: return "正在启动…"
        case .listening(let port): return "监听端口 \(port)，Bonjour \(LocalBridgeWire.serviceType)"
        case .failed(let message): return "启动失败：\(message)"
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func channelName(_ channel: Channel) -> String {
        switch channel {
        case .feishu: return "飞书"
        }
    }

    private func botStatusText(_ bot: BotConfiguration) -> String {
        guard bot.isEnabled else { return "已禁用" }
        switch feishu.state {
        case .connected: return "已连接"
        case .connecting, .reconnecting: return "连接中"
        case .disconnected: return "未连接"
        }
    }

    private func connectBot(_ bot: BotConfiguration) {
        guard let secret = botManager.secret(for: bot) else { return }
        feishu.connect(appId: bot.appId, appSecret: secret)
    }
}

// MARK: - 添加机器人 Sheet

struct AddBotSheet: View {

    @State private var registration = FeishuAppRegistration()
    @State private var qrURL = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("创建飞书机器人")
                .font(.headline)

            Text("用飞书扫描下方二维码，填写机器人名称即可")
                .foregroundColor(.secondary)
                .font(.callout)

            switch registration.state {
            case .idle, .initializing:
                ProgressView("正在初始化...")
                    .frame(width: 200, height: 200)

            case .waitingForScan, .polling:
                if let qrImage = QRCodeGenerator.generate(from: qrURL) {
                    Image(nsImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 200, height: 200)
                }

                if case .polling = registration.state {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("正在获取配置结果...").foregroundColor(.secondary)
                    }
                } else {
                    Text("等待扫码...").foregroundColor(.secondary)
                }

                Button("在浏览器中打开") {
                    if let url = URL(string: qrURL) { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(.link)

            case .success(let appId, let appSecret):
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.green)
                Text("机器人创建成功！")
                    .font(.title3)

                Button("完成") {
                    let bot = BotConfiguration(name: "我的语音助手", appId: appId)
                    BotManager.shared.addBot(bot, secret: appSecret)
                    FeishuClient.shared.connect(appId: appId, appSecret: appSecret)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)

            case .failed(let message):
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.red)
                Text(message).foregroundColor(.secondary)
                Button("重试") { registration.start() }
            }
        }
        .padding(24)
        .frame(width: 360, height: 420)
        .onAppear { registration.start() }
        .onDisappear { registration.cancel() }
        .onChange(of: registration.state) { _, newState in
            if case .waitingForScan(let url, _) = newState { qrURL = url }
        }
    }

}

// MARK: - 添加设备 Sheet

struct AddDeviceSheet: View {

    @State private var payload: LocalBridgePairingPayload?
    @State private var qrImage: NSImage?
    @State private var failed = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("添加设备")
                .font(.headline)

            Text("用 iPhone/iPad 上的 AIInput 扫描下方二维码")
                .foregroundColor(.secondary)
                .font(.callout)

            if let payload, let qrImage {
                Image(nsImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 220, height: 220)

                Text(payload.hosts.isEmpty ? "未找到可用地址，手机只能通过 Bonjour 发现"
                                           : payload.hosts.map(\.host).joined(separator: " · "))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            } else if failed {
                Text("配对密钥无法写入钥匙串，请重试")
                    .foregroundColor(.red)
                    .frame(width: 220, height: 220)
            } else {
                ProgressView("正在生成…")
                    .frame(width: 220, height: 220)
            }

            Text("二维码包含配对密钥，不要分享给他人")
                .font(.caption)
                .foregroundColor(.orange)

            Button("完成") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(width: 360, height: 440)
        .task {
            payload = await LocalBridgeService.shared.addDevice()
            qrImage = payload.flatMap { QRCodeGenerator.generate(from: $0.url) }
            failed = payload == nil
        }
    }
}
