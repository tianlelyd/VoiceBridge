import AppKit
import CryptoKit
import Foundation
import SystemConfiguration
import os

/// 局域网直连通道：管理已配对设备、生成配对二维码、按需启停 LocalBridgeServer，注入复用 TextInjector
@MainActor
@Observable
final class LocalBridgeService {

    static let shared = LocalBridgeService()

    private(set) var devices: [PairedDevice] = []
    /// 有配对设备时才监听
    private(set) var server: LocalBridgeServer?

    var state: LocalBridgeServer.State { server?.state ?? .stopped }
    var peers: [LocalBridgeServer.Peer] { server?.peers ?? [] }

    @ObservationIgnored private var hosts: [LocalBridgeHost] = []
    /// 启动和添加设备可能同时要地址，共用一次刷新，避免重复拉起 tailscale
    @ObservationIgnored private var hostsTask: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceBridge",
                                                    category: "LocalBridgeService")

    @ObservationIgnored private let storageURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("VoiceBridge", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("paired-devices.json")
    }()

    let macId: String = {
        let defaultsKey = "localBridgeMacId"
        if let id = UserDefaults.standard.string(forKey: defaultsKey) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: defaultsKey)
        return id
    }()

    // Host.current() 会做阻塞的 DNS 查询，这里只要电脑名
    let macName = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Mac"

    @ObservationIgnored private lazy var reaper = PendingPairingReaper(
        hasHandshaken: { [weak self] id in
            // 设备已经不在了（被手动吊销）也就不用再删
            guard let device = self?.devices.first(where: { $0.id == id }) else { return true }
            return device.lastSeenAt != nil
        },
        discard: { [weak self] id in
            guard let self, let device = self.devices.first(where: { $0.id == id }) else { return }
            self.logger.info("添加设备窗口关闭后一直没连上，清理设备 \(id, privacy: .public)")
            self.revoke(device)
        }
    )

    private init() {
        loadDevices()
        // 从没握手成功过的设备是上次没扫完的配对（窗口关掉后 App 在宽限期内退出了），不再保留
        for device in devices where device.lastSeenAt == nil {
            logger.info("清理未完成配对的设备 \(device.id, privacy: .public)")
            revoke(device)
        }
    }

    // MARK: - 启停

    func startIfNeeded() {
        guard !devices.isEmpty else { return stopServer() }
        guard server == nil else { return }

        let server = LocalBridgeServer(
            macId: macId,
            macName: macName,
            hosts: { [weak self] in self?.hosts ?? [] },
            keyForDevice: { [weak self] deviceId in
                guard let device = self?.devices.first(where: { $0.id == deviceId }),
                      let data = KeychainHelper.load(for: device.keychainKey) else { return nil }
                return SymmetricKey(data: data)
            },
            perform: Self.perform
        )
        server.onAuthenticated = { [weak self] deviceId, deviceName in
            self?.deviceSeen(deviceId, name: deviceName)
        }
        self.server = server
        server.start()
        Task { await refreshHosts() }
    }

    private func stopServer() {
        server?.stop()
        server = nil
    }

    // MARK: - 配对

    /// 新建一台设备并返回它的二维码载荷；设备第一次连上后用它上报的名字替换占位名。密钥存不进钥匙串时返回 nil
    func addDevice(name: String = "新设备") async -> LocalBridgePairingPayload? {
        let device = PairedDevice(id: UUID().uuidString, name: name, pairedAt: Date())
        let key = SymmetricKey(size: .bits256)
        guard KeychainHelper.save(key.withUnsafeBytes { Data($0) }, for: device.keychainKey) else {
            logger.error("配对密钥写入钥匙串失败")
            return nil
        }
        devices.append(device)
        saveDevices()
        logger.info("添加设备 \(device.id, privacy: .public)")

        startIfNeeded()
        await refreshHosts()
        return LocalBridgePairingPayload(macId: macId, macName: macName, deviceId: device.id, key: key,
                                         port: server?.port ?? LocalBridgeWire.defaultPort, hosts: hosts)
    }

    /// 「添加设备」窗口关掉时调用：没握手过的设备过一会儿还没连上就删掉
    func pairingWindowClosed(deviceId: String) {
        reaper.windowClosed(deviceId: deviceId)
    }

    func revoke(_ device: PairedDevice) {
        devices.removeAll { $0.id == device.id }
        KeychainHelper.delete(device.keychainKey)
        saveDevices()
        server?.disconnect(deviceId: device.id)
        logger.info("吊销设备 \(device.id, privacy: .public)")
        startIfNeeded()
    }

    func isConnected(_ device: PairedDevice) -> Bool {
        peers.contains { $0.deviceId == device.id }
    }

    private func deviceSeen(_ deviceId: String, name: String?) {
        guard let index = devices.firstIndex(where: { $0.id == deviceId }) else { return }
        devices[index].lastSeenAt = Date()
        if let name, !name.isEmpty { devices[index].name = name }
        saveDevices()
    }

    // MARK: - 注入

    private static func perform(_ action: LocalBridgeAction) -> InjectionOutcome {
        guard AXIsProcessTrusted() else { return .error("VoiceBridge 未获得辅助功能权限") }

        switch action {
        case .insert(let text, let then):
            let outcome = TextInjector.shared.inject(text)
            if case .injected = outcome, let then { press(then) }
            return outcome
        case .key(let key):
            return press(key)
        }
    }

    @discardableResult
    private static func press(_ key: LocalBridgeKey) -> InjectionOutcome {
        switch key {
        case .enter: TextInjector.shared.pressEnter()
        case .shiftEnter: TextInjector.shared.pressShiftEnter()
        case .clear: TextInjector.shared.clear()
        }
    }

    // MARK: - 地址

    private func refreshHosts() async {
        if let hostsTask { return await hostsTask.value }
        let task = Task {
            let magicDNS = await Self.tailscaleMagicDNS()
            hosts = LocalBridgeHosts.make(localHostName: SCDynamicStoreCopyLocalHostName(nil) as String?,
                                          addresses: Self.ipv4Addresses(),
                                          hardwareInterfaces: Self.hardwareInterfaces(),
                                          magicDNS: magicDNS)
            logger.info("直连地址: \(self.hosts.map(\.host).joined(separator: ", "), privacy: .public)")
        }
        hostsTask = task
        await task.value
        hostsTask = nil
    }

    /// 系统设置里的硬件端口（Wi-Fi、以太网、雷雳网桥），虚拟机/容器建的 bridge100+、vmnet* 不在里面
    private static func hardwareInterfaces() -> Set<String> {
        let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        return Set(interfaces.compactMap { SCNetworkInterfaceGetBSDName($0) as String? })
    }

    private static func ipv4Addresses() -> [(interface: String, ipv4: String)] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }

        var result: [(String, String)] = []
        var cursor = head
        while let entry = cursor?.pointee {
            defer { cursor = entry.ifa_next }
            guard let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            result.append((String(cString: entry.ifa_name), String(cString: host)))
        }
        return result
    }

    /// 读不到（没装、没登录、超时）就不放 MagicDNS 名，100.x 地址仍从网卡拿
    private static func tailscaleMagicDNS() async -> String? {
        let candidates = ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale",
                          "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
        guard let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else { return nil }

        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["status", "--json"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let timer = DispatchWorkItem { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: timer)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timer.cancel()
            return LocalBridgeHosts.magicDNSName(tailscaleStatus: data)
        }.value
    }

    // MARK: - 持久化

    private func loadDevices() {
        guard let data = try? Data(contentsOf: storageURL) else { return }
        do {
            devices = try JSONDecoder().decode([PairedDevice].self, from: data)
        } catch {
            logger.error("读取已配对设备失败: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func saveDevices() {
        do {
            try JSONEncoder().encode(devices).write(to: storageURL, options: .atomic)
        } catch {
            logger.error("保存已配对设备失败: \(error.localizedDescription, privacy: .public)")
        }
    }
}
