import CryptoKit
import XCTest

// 网络层可能出错的地方：监听起不来或端口没上报；连上后不发 hello；回复没发出去就断开（authFail 收不到）；
// 握手超时不断开；注入没回到主线程；吊销设备后旧连接还活着；已连接设备列表不更新；stop 后还能连进来。
final class LocalBridgeServerTests: XCTestCase {

    private let deviceId = UUID().uuidString
    private let key = SymmetricKey(size: .bits256)
    private var keys: [String: SymmetricKey] = [:]
    private var performed: [LocalBridgeAction] = []
    private var performedOnMain = true
    private var server: LocalBridgeServer!

    override func setUp() async throws {
        keys = [deviceId: key]
        server = await MainActor.run {
            LocalBridgeServer(
                macId: "MAC-TEST",
                macName: "Test Mac",
                port: 0,
                advertisesBonjour: false,
                handshakeTimeout: 1,
                hosts: { [] },
                keyForDevice: { [unowned self] in self.keys[$0] },
                perform: { [unowned self] action in
                    self.performedOnMain = self.performedOnMain && Thread.isMainThread
                    self.performed.append(action)
                    return .injected(.accessibility)
                }
            )
        }
        await MainActor.run { server.start() }
        try await waitUntil { await MainActor.run { self.server.port != nil } }
    }

    override func tearDown() async throws {
        await MainActor.run { server.stop() }
    }

    func testListenerReportsPortAndState() async throws {
        let state = await MainActor.run { server.state }
        guard case .listening(let port) = state else { return XCTFail("state=\(state)") }
        XCTAssertGreaterThan(port, 0)
    }

    func testFullInsertRoundTrip() async throws {
        let client = try await connectedClient()

        let auth = try await client.handshake(deviceId: deviceId, deviceName: "iPad", key: key)
        XCTAssertEqual(auth["type"] as? String, "authOK")
        XCTAssertEqual(client.hello?["macId"] as? String, "MAC-TEST")

        let ack = try await client.insert(id: "m1", text: "你好")
        XCTAssertEqual(ack["status"] as? String, "injected")
        XCTAssertEqual(ack["method"] as? String, "ax")
        XCTAssertEqual(performed, [.insert(text: "你好", then: nil)])
        XCTAssertTrue(performedOnMain)

        let pong = try await client.request(["type": "ping", "id": "p"])
        XCTAssertEqual(pong["type"] as? String, "pong")
        client.close()
    }

    func testAuthenticatedDeviceIsListedUntilDisconnect() async throws {
        let client = try await connectedClient()
        try await client.handshake(deviceId: deviceId, deviceName: "iPad", key: key)

        try await waitUntil { await MainActor.run { self.server.peers.count == 1 } }
        let peer = await MainActor.run { server.peers.first }
        XCTAssertEqual(peer?.deviceId, deviceId)
        XCTAssertEqual(peer?.deviceName, "iPad")

        client.close()
        try await waitUntil { await MainActor.run { self.server.peers.isEmpty } }
    }

    func testWrongKeyGetsAuthFailAndIsDisconnected() async throws {
        let client = try await connectedClient()

        let reply = try await client.handshake(deviceId: deviceId, key: SymmetricKey(size: .bits256))

        XCTAssertEqual(reply["type"] as? String, "authFail")
        XCTAssertEqual(reply["reason"] as? String, "badMac")
        let closed = await client.waitForClose()
        XCTAssertTrue(closed)
        XCTAssertTrue(performed.isEmpty)
    }

    func testSilentClientIsDroppedAfterHandshakeTimeout() async throws {
        let client = try await connectedClient()
        _ = try await client.nextFrame()

        let closed = await client.waitForClose(timeout: 3)

        XCTAssertTrue(closed)
    }

    func testRevokingDeviceDropsItsConnection() async throws {
        let client = try await connectedClient()
        try await client.handshake(deviceId: deviceId, key: key)
        try await waitUntil { await MainActor.run { self.server.peers.count == 1 } }

        keys[deviceId] = nil
        await MainActor.run { server.disconnect(deviceId: deviceId) }

        let closed = await client.waitForClose()
        XCTAssertTrue(closed)
    }

    func testStoppedServerRefusesConnections() async throws {
        let port = try await MainActor.run { try XCTUnwrap(server.port) }
        await MainActor.run { server.stop() }

        let client = LocalBridgeTestClient(host: "127.0.0.1", port: port)
        do {
            try await client.connect(timeout: 1)
            _ = try await client.nextFrame(timeout: 1)
            XCTFail("停止后不应再握手")
        } catch {}
        client.close()
    }

    // MARK: - Helpers

    private func connectedClient() async throws -> LocalBridgeTestClient {
        let port = try await MainActor.run { try XCTUnwrap(server.port) }
        let client = LocalBridgeTestClient(host: "127.0.0.1", port: port)
        try await client.connect()
        return client
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("等待条件超时")
    }
}
