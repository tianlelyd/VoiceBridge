import CryptoKit
import Foundation

enum LocalBridgeKey: String, Equatable {
    case enter
    case shiftEnter
    case clear
}

enum LocalBridgeAction: Equatable {
    case insert(text: String, then: LocalBridgeKey?)
    case key(LocalBridgeKey)
}

/// 一条消息的处理结果，去重表里存的也是它，重发时原样放进 duplicate 回执的 first 里
struct LocalBridgeAck: Equatable {

    enum Status: String {
        case injected, noFocus, expired, error
    }

    let status: Status
    var method: String?
    var message: String?

    init(status: Status, method: String? = nil, message: String? = nil) {
        self.status = status
        self.method = method
        self.message = message
    }

    init(_ outcome: InjectionOutcome) {
        switch outcome {
        case .injected(let method): self.init(status: .injected, method: method.rawValue)
        case .noFocus: self.init(status: .noFocus)
        case .error(let message): self.init(status: .error, message: message)
        }
    }

    var fields: [String: Any] {
        var out: [String: Any] = ["status": status.rawValue]
        if let method { out["method"] = method }
        if let message { out["message"] = message }
        return out
    }
}

/// 一条局域网连接的协议状态机：hello → auth → authOK，之后收加密的 insert/key/ping。
/// 不碰网络，输入一帧、输出要发的帧和是否断开，网络由 LocalBridgeServer 负责。
final class LocalBridgeSession {

    enum Output: Equatable {
        case send(Data)
        case close
    }

    struct Environment {
        let macId: String
        let macName: String
        let hosts: () -> [[String: String]]
        let keyForDevice: (String) -> SymmetricKey?
        let perform: (LocalBridgeAction) -> InjectionOutcome
        let deduplicator: MessageDeduplicator<LocalBridgeAck>
        var clock: () -> Date = Date.init
    }

    static let maxConsecutiveDecryptFailures = 3
    static let defaultTTLMs: Double = 10_000

    private let environment: Environment
    private let challenge = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
    private var sessionKey: SymmetricKey?
    private var decryptFailures = 0

    private(set) var deviceId: String?
    private(set) var deviceName: String?
    /// 最近一条 insert/key 的处理结果，给日志和界面用
    private(set) var lastAck: (id: String, ack: LocalBridgeAck)?

    var isAuthenticated: Bool { sessionKey != nil }

    init(environment: Environment) {
        self.environment = environment
    }

    func start() -> [Output] {
        [.send(LocalBridgeWire.json([
            "type": "hello",
            "v": LocalBridgeWire.version,
            "macId": environment.macId,
            "macName": environment.macName,
            "challenge": challenge.base64EncodedString(),
        ]))]
    }

    func receive(_ data: Data) -> [Output] {
        guard let sessionKey else { return authenticate(data) }

        guard let frame = LocalBridgeWire.parse(data),
              let message = try? LocalBridgeWire.open(frame, key: sessionKey) else {
            decryptFailures += 1
            return decryptFailures >= Self.maxConsecutiveDecryptFailures ? [.close] : []
        }
        decryptFailures = 0

        guard let reply = handle(message),
              let sealed = try? LocalBridgeWire.seal(reply, key: sessionKey) else { return [] }
        return [.send(sealed)]
    }

    // MARK: - 握手

    private func authenticate(_ data: Data) -> [Output] {
        guard let frame = LocalBridgeWire.parse(data), frame["type"] as? String == "auth" else {
            return [.close]
        }

        func fail(_ reason: String) -> [Output] {
            [.send(LocalBridgeWire.json(["type": "authFail", "reason": reason])), .close]
        }

        // 原型客户端不带 v，按 1 处理
        guard (frame["v"] as? Int ?? LocalBridgeWire.version) == LocalBridgeWire.version else {
            return fail("version")
        }
        guard let device = frame["deviceId"] as? String, let mac = frame["mac"] as? String else {
            return fail("badMac")
        }
        guard let key = environment.keyForDevice(device) else { return fail("unknownDevice") }
        guard LocalBridgeWire.isValidHMAC(mac, key: key, challenge: challenge, deviceId: device) else {
            return fail("badMac")
        }

        deviceId = device
        deviceName = frame["deviceName"] as? String
        sessionKey = LocalBridgeWire.sessionKey(key: key, challenge: challenge)

        return [.send(LocalBridgeWire.json([
            "type": "authOK",
            "v": LocalBridgeWire.version,
            "sessionId": UUID().uuidString,
            "macId": environment.macId,
            "serverTime": environment.clock().timeIntervalSince1970,
            "hosts": environment.hosts(),
        ]))]
    }

    // MARK: - 消息

    private func handle(_ message: [String: Any]) -> [String: Any]? {
        let type = message["type"] as? String
        if type == "ping" {
            return ["type": "pong", "id": message["id"] ?? ""]
        }

        guard let id = message["id"] as? String, !id.isEmpty else { return nil }

        if let first = environment.deduplicator.value(for: id) {
            return ack(id: id, ["status": "duplicate", "first": first.fields])
        }

        let started = environment.clock()
        let result = process(type: type, message: message, now: started)
        environment.deduplicator.record(id, value: result)
        lastAck = (id, result)

        var fields = result.fields
        if result.status == .injected {
            fields["injectMs"] = Int(environment.clock().timeIntervalSince(started) * 1000)
        }
        return ack(id: id, fields)
    }

    private func process(type: String?, message: [String: Any], now: Date) -> LocalBridgeAck {
        let action: LocalBridgeAction
        switch type {
        case "insert":
            guard let text = message["text"] as? String, !text.isEmpty else {
                return LocalBridgeAck(status: .error, message: "insert 缺少 text")
            }
            var then: LocalBridgeKey?
            if let raw = message["then"] as? String {
                guard let key = LocalBridgeKey(rawValue: raw), key != .clear else {
                    return LocalBridgeAck(status: .error, message: "不支持的 then: \(raw)")
                }
                then = key
            }
            action = .insert(text: text, then: then)
        case "key":
            guard let key = (message["kind"] as? String).flatMap(LocalBridgeKey.init(rawValue:)) else {
                return LocalBridgeAck(status: .error, message: "不支持的 kind: \(message["kind"] ?? "nil")")
            }
            action = .key(key)
        default:
            return LocalBridgeAck(status: .error, message: "不支持的消息类型: \(type ?? "nil")")
        }

        // 过期按 Mac 时钟判：createdAt 是秒，ttlMs 是毫秒
        guard let createdAt = message["createdAt"] as? Double else {
            return LocalBridgeAck(status: .error, message: "缺少 createdAt")
        }
        let ttl = (message["ttlMs"] as? Double ?? Self.defaultTTLMs) / 1000
        guard now.timeIntervalSince1970 <= createdAt + ttl else {
            return LocalBridgeAck(status: .expired)
        }

        return LocalBridgeAck(environment.perform(action))
    }

    private func ack(id: String, _ fields: [String: Any]) -> [String: Any] {
        fields.merging(["type": "ack", "id": id,
                        "serverTime": environment.clock().timeIntervalSince1970]) { $1 }
    }
}
