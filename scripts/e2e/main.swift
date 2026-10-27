import CryptoKit
import Foundation

// 局域网直连端到端：扫码载荷 → 连接 → 握手 → insert → 真实注入测试输入框 → 回执。
// 用法：e2e-client <配对二维码文件> <输入框内容文件> <测试窗口 pid> <报告.md>

@main
struct E2E {

    struct Failure: Error, CustomStringConvertible { let description: String }

    static var results: [(name: String, passed: Bool, detail: String)] = []

    static func main() async {
        let args = CommandLine.arguments
        guard args.count == 5, let windowPid = Int32(args[3]) else {
            print("用法: e2e-client <pairing> <field> <window-pid> <report.md>")
            exit(2)
        }
        let fieldPath = args[2]
        let reportPath = args[4]

        let payload: LocalBridgePairingPayload
        do {
            let url = try String(contentsOfFile: args[1], encoding: .utf8)
            payload = try LocalBridgePairingPayload(url: url.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            print("读不出配对载荷: \(error)")
            exit(2)
        }
        log("配对载荷 macId=\(payload.macId) port=\(payload.port) hosts=\(payload.hosts.map(\.host))")

        func field() -> String { (try? String(contentsOfFile: fieldPath, encoding: .utf8)) ?? "" }
        func waitForField(_ expected: String) async -> Bool {
            for _ in 0..<40 {
                if field() == expected { return true }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return false
        }

        await check("配对载荷：版本、密钥、地址") {
            guard !payload.hosts.isEmpty else { throw Failure(description: "没有候选地址") }
            return "deviceId=\(payload.deviceId) hosts=\(payload.hosts.map { "\($0.kind.rawValue):\($0.host)" })"
        }

        let client = LocalBridgeTestClient(host: "127.0.0.1", port: payload.port)
        await check("连接与握手（authOK）") {
            try await connect(client)
            let auth = try await client.handshake(deviceId: payload.deviceId, deviceName: "E2E", key: payload.key)
            guard auth["type"] as? String == "authOK" else { throw Failure(description: "\(auth)") }
            guard client.hello?["macId"] as? String == payload.macId else { throw Failure(description: "hello macId 不符") }
            return "hello=\(json(client.hello ?? [:]))\nauthOK=\(json(auth))"
        }

        let text = "VoiceBridge 局域网 e2e \(Int.random(in: 1000...9999))"
        let firstId = UUID().uuidString
        await check("insert → 注入测试输入框 → ack(injected)") {
            let ack = try await client.insert(id: firstId, text: text)
            guard ack["status"] as? String == "injected" else { throw Failure(description: json(ack)) }
            guard await waitForField(text) else { throw Failure(description: "输入框内容=\(field().debugDescription)，ack=\(json(ack))") }
            return "ack=\(json(ack))\n输入框=\(field().debugDescription)"
        }

        await check("重复 id → duplicate，回原结果，不重复注入") {
            let ack = try await client.insert(id: firstId, text: text)
            let first = ack["first"] as? [String: Any]
            guard ack["status"] as? String == "duplicate", first?["status"] as? String == "injected" else {
                throw Failure(description: json(ack))
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard field() == text else { throw Failure(description: "输入框被改动: \(field().debugDescription)") }
            return "ack=\(json(ack))"
        }

        await check("过期消息 → expired，不注入") {
            let ack = try await client.insert(text: "不应出现", createdAt: Date().addingTimeInterval(-60), ttlMs: 10_000)
            guard ack["status"] as? String == "expired" else { throw Failure(description: json(ack)) }
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard field() == text else { throw Failure(description: "输入框被改动: \(field().debugDescription)") }
            return "ack=\(json(ack))"
        }

        await check("ping → pong") {
            let pong = try await client.request(["type": "ping", "id": "e2e-ping"])
            guard pong["type"] as? String == "pong" else { throw Failure(description: json(pong)) }
            return json(pong)
        }

        await check("焦点不在输入框 → noFocus，不注入") {
            try await signalWindow(windowPid, SIGUSR1)
            let ack = try await client.insert(text: "不应出现")
            try await signalWindow(windowPid, SIGUSR2)
            guard ack["status"] as? String == "noFocus" else { throw Failure(description: json(ack)) }
            guard field() == text else { throw Failure(description: "输入框被改动: \(field().debugDescription)") }
            return "ack=\(json(ack))"
        }
        client.close()

        await check("错误密钥 → authFail(badMac) 并断开") {
            let bad = LocalBridgeTestClient(host: "127.0.0.1", port: payload.port)
            defer { bad.close() }
            try await connect(bad)
            let reply = try await bad.handshake(deviceId: payload.deviceId, key: SymmetricKey(size: .bits256))
            guard reply["type"] as? String == "authFail", reply["reason"] as? String == "badMac" else {
                throw Failure(description: json(reply))
            }
            guard await bad.waitForClose() else { throw Failure(description: "服务端没有断开") }
            return json(reply)
        }

        await check("未配对设备 → authFail(unknownDevice) 并断开") {
            let stranger = LocalBridgeTestClient(host: "127.0.0.1", port: payload.port)
            defer { stranger.close() }
            try await connect(stranger)
            let reply = try await stranger.handshake(deviceId: UUID().uuidString, key: payload.key)
            guard reply["type"] as? String == "authFail", reply["reason"] as? String == "unknownDevice" else {
                throw Failure(description: json(reply))
            }
            guard await stranger.waitForClose() else { throw Failure(description: "服务端没有断开") }
            return json(reply)
        }

        if let lan = payload.hosts.first(where: { $0.kind == .lan && $0.host.first?.isNumber == true }) {
            await check("经局域网地址 \(lan.host) 直连握手") {
                let remote = LocalBridgeTestClient(host: lan.host, port: payload.port)
                defer { remote.close() }
                try await connect(remote)
                let auth = try await remote.handshake(deviceId: payload.deviceId, deviceName: "E2E", key: payload.key)
                guard auth["type"] as? String == "authOK" else { throw Failure(description: json(auth)) }
                return "authOK hosts=\(json(["hosts": auth["hosts"] ?? []]))"
            }
        }

        writeReport(to: reportPath, payload: payload)
        exit(results.allSatisfy(\.passed) ? 0 : 1)
    }

    // MARK: - Helpers

    static func check(_ name: String, _ body: () async throws -> String) async {
        do {
            let detail = try await body()
            results.append((name, true, detail))
            log("✅ \(name)")
        } catch {
            results.append((name, false, "\(error)"))
            log("❌ \(name): \(error)")
        }
    }

    /// App 刚重启时监听可能还没起来，重试几次
    static func connect(_ client: LocalBridgeTestClient) async throws {
        var lastError: Error?
        for _ in 0..<20 {
            do { return try await client.connect(timeout: 1) } catch { lastError = error }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        throw lastError ?? Failure(description: "连接失败")
    }

    static func signalWindow(_ pid: Int32, _ sig: Int32) async throws {
        guard kill(pid, sig) == 0 else { throw Failure(description: "测试窗口进程 \(pid) 不在了") }
        try await Task.sleep(nanoseconds: 300_000_000)
    }

    static func json(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return "\(obj)" }
        return String(decoding: data, as: UTF8.self)
    }

    static func log(_ line: String) {
        print("[\(ISO8601DateFormatter().string(from: Date()))] \(line)")
        fflush(stdout)
    }

    static func writeReport(to path: String, payload: LocalBridgePairingPayload) {
        let passed = results.filter(\.passed).count
        var md = """
        # VoiceBridge 局域网直连 e2e 结果

        - 时间：\(ISO8601DateFormatter().string(from: Date()))
        - 目标：/Applications/VoiceBridge.app（macId \(payload.macId)，端口 \(payload.port)）
        - 结果：\(passed)/\(results.count) 通过


        """
        for (index, result) in results.enumerated() {
            md += "## \(index + 1). \(result.passed ? "✅" : "❌") \(result.name)\n\n```\n\(result.detail)\n```\n\n"
        }
        try? md.write(toFile: path, atomically: true, encoding: .utf8)
        log("报告: \(path)（\(passed)/\(results.count) 通过）")
    }
}
