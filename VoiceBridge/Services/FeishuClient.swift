import Foundation
import os

// MARK: - 连接状态

enum FeishuConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)
}

// MARK: - FeishuClient

@Observable
final class FeishuClient {

    static let shared = FeishuClient()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceBridge",
                                category: "FeishuClient")

    private(set) var state: FeishuConnectionState = .disconnected

    var onTextReceived: ((String) -> Void)?
    var onEnterReceived: (() -> Void)?
    var onClearReceived: (() -> Void)?
    var onShiftEnterReceived: (() -> Void)?

    private var webSocketTask: URLSessionWebSocketTask?
    private var pingTimer: Timer?
    private var pingInterval: TimeInterval = 120
    private var reconnectCount: Int = -1
    private var reconnectInterval: TimeInterval = 120
    private var reconnectNonce: TimeInterval = 5
    private var currentReconnectAttempt = 0
    private var shouldReconnect = false

    private var appId: String = ""
    private var appSecret: String = ""

    // 消息去重：Dictionary O(1) 查找 + Array FIFO 淘汰
    private var dedupIndex: [String: Date] = [:]
    private var dedupQueue: [(id: String, time: Date)] = []
    private let dedupTTL: TimeInterval = 600
    private let dedupMaxEntries = 2000
    private let messageExpirySeconds: TimeInterval = 1800

    private let session = URLSession(configuration: .default)
    private let jsonDecoder = JSONDecoder()
    private static let endpointURL = URL(string: "https://open.feishu.cn/callback/ws/endpoint")!

    private init() {}

    // MARK: - Public API

    func connectWithStoredCredentials() {
        guard let bot = BotManager.shared.bots.first(where: { $0.isEnabled }),
              let secret = BotManager.shared.secret(for: bot) else { return }
        connect(appId: bot.appId, appSecret: secret)
    }

    func connect(appId: String, appSecret: String) {
        self.appId = appId
        self.appSecret = appSecret
        shouldReconnect = true
        currentReconnectAttempt = 0
        startConnection()
    }

    func disconnect() {
        shouldReconnect = false
        stopPingTimer()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        state = .disconnected
        logger.info("已断开连接")
    }

    // MARK: - 建连流程

    private func startConnection() {
        guard shouldReconnect else { return }

        if currentReconnectAttempt == 0 {
            state = .connecting
        } else {
            state = .reconnecting(attempt: currentReconnectAttempt)
        }

        Task {
            do {
                let wsURL = try await fetchEndpoint()
                try await connectWebSocket(url: wsURL)
            } catch {
                logger.error("连接失败: \(error.localizedDescription)")
                scheduleReconnect()
            }
        }
    }

    // MARK: - 获取 WebSocket URL

    private func fetchEndpoint() async throws -> URL {
        var request = URLRequest(url: Self.endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("zh", forHTTPHeaderField: "locale")

        let body: [String: String] = ["AppID": appId, "AppSecret": appSecret]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, httpResponse) = try await session.data(for: request)

        let statusCode = (httpResponse as? HTTPURLResponse)?.statusCode ?? 0
        logger.info("Endpoint 响应 HTTP \(statusCode), body=\(String(data: data, encoding: .utf8) ?? "<binary>")")

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FeishuError.invalidResponse
        }

        let code = (json["code"] as? Int) ?? (json["Code"] as? Int) ?? -1
        guard code == 0 else {
            let msg = (json["msg"] as? String) ?? (json["Msg"] as? String) ?? "unknown"
            throw FeishuError.apiError(code: code, message: msg)
        }

        let dataDict = (json["data"] as? [String: Any]) ?? (json["Data"] as? [String: Any])
        guard let dataDict else {
            throw FeishuError.invalidResponse
        }

        let wsURLString = (dataDict["URL"] as? String)
            ?? (dataDict["url"] as? String)
            ?? ""
        guard !wsURLString.isEmpty, let wsURL = URL(string: wsURLString) else {
            throw FeishuError.invalidResponse
        }

        let configDict = (dataDict["ClientConfig"] as? [String: Any])
            ?? (dataDict["client_config"] as? [String: Any])
        if let configDict {
            if let pi = configDict["PingInterval"] as? Int, pi > 0 { pingInterval = TimeInterval(pi) }
            if let rc = configDict["ReconnectCount"] as? Int { reconnectCount = rc }
            if let ri = configDict["ReconnectInterval"] as? Int, ri > 0 { reconnectInterval = TimeInterval(ri) }
            if let rn = configDict["ReconnectNonce"] as? Int, rn > 0 { reconnectNonce = TimeInterval(rn) }
        }

        logger.info("获取 WebSocket URL 成功, pingInterval=\(self.pingInterval)s")
        return wsURL
    }

    // MARK: - WebSocket 连接

    private func connectWebSocket(url: URL) async throws {
        let task = session.webSocketTask(with: url)
        self.webSocketTask = task
        task.resume()

        state = .connected
        currentReconnectAttempt = 0
        logger.info("WebSocket 已连接")

        startPingTimer()
        receiveLoop()
    }

    // MARK: - 接收消息循环

    private func receiveLoop() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }

            DispatchQueue.main.async {
                switch result {
                case .success(let message):
                    switch message {
                    case .data(let data):
                        self.handleBinaryMessage(data)
                    case .string(let text):
                        self.logger.debug("收到文本消息（非预期）: \(text)")
                    @unknown default:
                        break
                    }
                    self.receiveLoop()

                case .failure(let error):
                    self.logger.error("WebSocket 接收失败: \(error.localizedDescription)")
                    self.handleDisconnect()
                }
            }
        }
    }

    // MARK: - 处理二进制消息（Protobuf Frame）

    private func handleBinaryMessage(_ data: Data) {
        do {
            let frame = try PBDecoder.decodeFrame(from: data)
            let messageType = frame.headerValue(for: "type") ?? ""

            switch frame.method {
            case 0:
                handleControlFrame(frame, messageType: messageType)
            case 1:
                handleDataFrame(frame, messageType: messageType)
            default:
                logger.debug("未知 method: \(frame.method)")
            }
        } catch {
            logger.error("Protobuf 解码失败: \(error.localizedDescription)")
        }
    }

    private func handleControlFrame(_ frame: PBFrame, messageType: String) {
        if messageType == "pong" {
            logger.debug("收到 pong")
            if !frame.payload.isEmpty,
               let config = try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any],
               let pi = config["PingInterval"] as? Int, pi > 0 {
                pingInterval = TimeInterval(pi)
                startPingTimer()
            }
        }
    }

    private func handleDataFrame(_ frame: PBFrame, messageType: String) {
        let frameMessageId = frame.headerValue(for: "message_id") ?? ""

        sendACK(frame: frame, messageId: frameMessageId)

        guard messageType == "event" else {
            logger.debug("忽略非 event 消息类型: \(messageType)")
            return
        }

        guard !frame.payload.isEmpty else { return }

        do {
            let event = try jsonDecoder.decode(FeishuEventWrapper.self, from: frame.payload)

            let eventId = event.event?.message?.messageId ?? event.header?.eventId
            if let eventId, !eventId.isEmpty {
                if isDuplicate(eventId) {
                    logger.info("跳过重复事件: \(eventId)")
                    return
                }
                recordMessage(eventId)
            }

            let createTimeStr = event.event?.message?.createTime ?? event.header?.createTime
            if let createTimeStr,
               let createTimeMs = Double(createTimeStr) {
                let eventAge = Date().timeIntervalSince1970 - (createTimeMs / 1000.0)
                if eventAge > messageExpirySeconds {
                    logger.info("丢弃过期事件 (age=\(Int(eventAge))s): \(event.header?.eventType ?? "unknown")")
                    return
                }
            }

            if event.header?.eventType == "application.bot.menu_v6" {
                guard let eventKey = event.event?.eventKey, !eventKey.isEmpty else {
                    logger.debug("忽略缺少 event_key 的机器人菜单事件")
                    return
                }

                logger.info("收到机器人菜单事件: \(eventKey)")
                switch eventKey {
                case "enter":
                    self.onEnterReceived?()
                case "clear":
                    self.onClearReceived?()
                case "shift_enter":
                    self.onShiftEnterReceived?()
                default:
                    logger.debug("忽略未处理的机器人菜单事件: \(eventKey)")
                }
                return
            }

            guard let message = event.event?.message,
                  let text = message.plainText,
                  !text.isEmpty else {
                return
            }

            logger.info("收到文本消息: \(text.prefix(50))")
            self.onTextReceived?(text)
        } catch {
            logger.error("事件 JSON 解析失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 消息去重（Dictionary O(1) + FIFO 淘汰）

    private func isDuplicate(_ messageId: String) -> Bool {
        guard let recorded = dedupIndex[messageId] else { return false }
        return Date().timeIntervalSince(recorded) < dedupTTL
    }

    private func recordMessage(_ messageId: String) {
        let now = Date()
        dedupIndex[messageId] = now
        dedupQueue.append((id: messageId, time: now))

        let expiredCount = dedupQueue.prefix(while: { now.timeIntervalSince($0.time) > dedupTTL }).count
        if expiredCount > 0 {
            for i in 0..<expiredCount { dedupIndex.removeValue(forKey: dedupQueue[i].id) }
            dedupQueue.removeFirst(expiredCount)
        }

        if dedupQueue.count > dedupMaxEntries {
            let overflow = dedupQueue.count - dedupMaxEntries
            for i in 0..<overflow { dedupIndex.removeValue(forKey: dedupQueue[i].id) }
            dedupQueue.removeFirst(overflow)
        }
    }

    // MARK: - ACK 回复

    private func sendACK(frame: PBFrame, messageId: String) {
        var ackFrame = PBFrame()
        ackFrame.seqID = frame.seqID
        ackFrame.logID = frame.logID
        ackFrame.service = frame.service
        ackFrame.method = frame.method
        ackFrame.headers = [
            PBHeader(key: "type", value: "event"),
            PBHeader(key: "message_id", value: messageId),
        ]
        ackFrame.payload = (try? JSONSerialization.data(withJSONObject: ["code": 0])) ?? Data()

        let data = PBEncoder.encodeFrame(ackFrame)
        webSocketTask?.send(.data(data)) { [weak self] error in
            if let error {
                self?.logger.error("ACK 发送失败: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - 心跳

    private func startPingTimer() {
        stopPingTimer()
        pingTimer = Timer.scheduledTimer(withTimeInterval: pingInterval, repeats: true) { [weak self] _ in
            self?.sendPing()
        }
    }

    private func stopPingTimer() {
        pingTimer?.invalidate()
        pingTimer = nil
    }

    private func sendPing() {
        var frame = PBFrame()
        frame.method = 0
        frame.headers = [PBHeader(key: "type", value: "ping")]

        let data = PBEncoder.encodeFrame(frame)
        webSocketTask?.send(.data(data)) { [weak self] error in
            if let error {
                self?.logger.error("Ping 发送失败: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - 断线重连

    private func handleDisconnect() {
        stopPingTimer()
        webSocketTask = nil

        guard shouldReconnect else {
            state = .disconnected
            return
        }

        scheduleReconnect()
    }

    private func scheduleReconnect() {
        if reconnectCount >= 0 && currentReconnectAttempt >= reconnectCount {
            logger.error("重连次数已耗尽 (\(self.reconnectCount))")
            state = .disconnected
            return
        }

        currentReconnectAttempt += 1
        state = .reconnecting(attempt: currentReconnectAttempt)

        let delay: TimeInterval = currentReconnectAttempt == 1
            ? Double.random(in: 0...reconnectNonce)
            : reconnectInterval

        logger.info("将在 \(String(format: "%.1f", delay))s 后重连 (第 \(self.currentReconnectAttempt) 次)")

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.startConnection()
        }
    }
}

// MARK: - Errors

enum FeishuError: LocalizedError {
    case invalidResponse
    case apiError(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "飞书 API 返回无效响应"
        case .apiError(let code, let message):
            return "飞书 API 错误 (\(code)): \(message)"
        }
    }
}
