import CryptoKit
import Foundation
import Network

/// 手机端协议的最小实现（照 ai-input 原型 MacLinkExperiment 的握手和收发），XCTest 和端到端命令行 scripts/e2e 共用。
/// 不依赖 XCTest；直连一律用 ws:// URL 端点（原型实测 .hostPort + IP 字面量在 iOS 上会 ECONNABORTED）。
final class LocalBridgeTestClient {

    struct ClientError: Error, CustomStringConvertible {
        let description: String
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "LocalBridgeTestClient")
    private var inbox: [[String: Any]] = []
    private var waiter: CheckedContinuation<[String: Any], Error>?
    private var closedError: Error?
    private(set) var sessionKey: SymmetricKey?
    private(set) var hello: [String: Any]?

    init(host: String, port: UInt16) {
        let url = URL(string: "ws://\(host):\(port)/")!
        connection = NWConnection(to: .url(url), using: LocalBridgeWire.parameters())
    }

    func connect(timeout: TimeInterval = 3) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            func finish(_ error: Error?) {
                guard !resumed else { return }
                resumed = true
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    finish(nil)
                    self?.receiveLoop()
                case .failed(let error), .waiting(let error):
                    finish(error)
                    self?.fail(error)
                case .cancelled:
                    finish(ClientError(description: "连接已取消"))
                    self?.fail(ClientError(description: "连接已关闭"))
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(ClientError(description: "连接超时")) }
        }
    }

    /// 收 hello、发 auth，返回 authOK 或 authFail 帧；authOK 时派生会话密钥
    @discardableResult
    func handshake(deviceId: String, deviceName: String = "TestClient", key: SymmetricKey) async throws -> [String: Any] {
        let hello = try await nextFrame()
        self.hello = hello
        guard hello["type"] as? String == "hello",
              let challenge = Data(base64Encoded: hello["challenge"] as? String ?? "") else {
            throw ClientError(description: "期望 hello，收到 \(hello)")
        }
        sendRaw(LocalBridgeWire.json([
            "type": "auth", "v": LocalBridgeWire.version,
            "deviceId": deviceId, "deviceName": deviceName,
            "mac": LocalBridgeWire.hmac(key: key, challenge: challenge, deviceId: deviceId),
            "sentAt": Date().timeIntervalSince1970,
        ]))
        let reply = try await nextFrame()
        if reply["type"] as? String == "authOK" {
            sessionKey = LocalBridgeWire.sessionKey(key: key, challenge: challenge)
        }
        return reply
    }

    /// 加密发一条消息，等下一帧回复并解密
    func request(_ message: [String: Any], timeout: TimeInterval = 5) async throws -> [String: Any] {
        guard let sessionKey else { throw ClientError(description: "还没握手") }
        sendRaw(try LocalBridgeWire.seal(message, key: sessionKey))
        return try LocalBridgeWire.open(try await nextFrame(timeout: timeout), key: sessionKey)
    }

    func insert(id: String = UUID().uuidString, text: String, createdAt: Date = Date(),
                ttlMs: Int = 10_000, then: String? = nil) async throws -> [String: Any] {
        var message: [String: Any] = ["type": "insert", "id": id, "round": id, "text": text,
                                      "createdAt": createdAt.timeIntervalSince1970, "ttlMs": ttlMs]
        if let then { message["then"] = then }
        return try await request(message)
    }

    func sendRaw(_ data: Data) {
        LocalBridgeWire.send(data, on: connection)
    }

    func nextFrame(timeout: TimeInterval = 5) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if !inbox.isEmpty { return continuation.resume(returning: inbox.removeFirst()) }
                if let closedError { return continuation.resume(throwing: closedError) }
                waiter = continuation
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard let self, let waiter = self.waiter else { return }
                    self.waiter = nil
                    waiter.resume(throwing: ClientError(description: "等回复超时"))
                }
            }
        }
    }

    /// 等对端断开；超时内没断返回 false
    func waitForClose(timeout: TimeInterval = 3) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let closed = queue.sync { closedError != nil }
            if closed { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    func close() {
        connection.cancel()
    }

    private func receiveLoop() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty, let frame = LocalBridgeWire.parse(data) {
                self.deliver(frame)
            }
            if let error { return self.fail(error) }
            if self.connection.state == .ready { self.receiveLoop() }
        }
    }

    private func deliver(_ frame: [String: Any]) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: frame)
        } else {
            inbox.append(frame)
        }
    }

    private func fail(_ error: Error) {
        if closedError == nil { closedError = error }
        if let waiter {
            self.waiter = nil
            waiter.resume(throwing: error)
        }
    }
}
