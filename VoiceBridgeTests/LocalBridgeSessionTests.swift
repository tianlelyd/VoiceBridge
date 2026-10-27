import CryptoKit
import XCTest

// 会话状态机可能出错的地方（先列出来，测试逐条覆盖）：
// 1. 握手：hello 缺字段；未知 deviceId 被放行；HMAC 错误被放行；版本不符没拒；认证前就处理了加密帧或 insert。
// 2. 加密：会话密钥没按 challenge 派生（换连接后旧密文仍能解）；解密失败没计数、没在连续 3 次后断开；成功一次后计数没清零。
// 3. insert：过期判断用错单位（createdAt 是秒、ttlMs 是毫秒）；过期仍注入；重复 id 再次注入；duplicate 没带第一次结果；
//    注入结果到 status/method 的映射错；then 回车在注入失败时仍触发。
// 4. key：kind 映射错；未知 kind 没回 error。
// 5. ping 没回 pong 或 id 没带回。
// 6. 消息缺 id 或字段类型不对时崩溃，而不是回 error。
final class LocalBridgeSessionTests: XCTestCase {

    private let deviceId = "11111111-2222-3333-4444-555555555555"
    private let key = SymmetricKey(size: .bits256)
    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    private var performed: [LocalBridgeAction] = []
    private var nextOutcome: InjectionOutcome = .injected(.accessibility)
    private var dedup = MessageDeduplicator<LocalBridgeAck>()

    private func makeSession() -> LocalBridgeSession {
        LocalBridgeSession(environment: LocalBridgeSession.Environment(
            macId: "MAC-1",
            macName: "Test Mac",
            hosts: { [LocalBridgeHost(kind: .lan, host: "test.local")] },
            keyForDevice: { [unowned self] in $0 == self.deviceId ? self.key : nil },
            perform: { [unowned self] action in
                self.performed.append(action)
                return self.nextOutcome
            },
            deduplicator: dedup,
            clock: { [unowned self] in self.now }
        ))
    }

    // MARK: - 握手

    func testStartSendsHelloWithChallenge() throws {
        let session = makeSession()

        let hello = try XCTUnwrap(plainFrames(session.start()).first)

        XCTAssertEqual(hello["type"] as? String, "hello")
        XCTAssertEqual(hello["v"] as? Int, 1)
        XCTAssertEqual(hello["macId"] as? String, "MAC-1")
        XCTAssertEqual(hello["macName"] as? String, "Test Mac")
        XCTAssertEqual(Data(base64Encoded: hello["challenge"] as? String ?? "")?.count, 32)
    }

    func testValidAuthIsAccepted() throws {
        let session = makeSession()
        let challenge = try challenge(of: session)

        let outputs = session.receive(authFrame(challenge: challenge))
        let reply = try XCTUnwrap(plainFrames(outputs).first)

        XCTAssertEqual(reply["type"] as? String, "authOK")
        XCTAssertEqual(reply["v"] as? Int, 1)
        XCTAssertEqual(reply["macId"] as? String, "MAC-1")
        XCTAssertEqual(reply["serverTime"] as? Double, now.timeIntervalSince1970)
        XCTAssertEqual((reply["hosts"] as? [[String: String]])?.first?["host"], "test.local")
        XCTAssertFalse(outputs.contains(.close))
        XCTAssertEqual(session.deviceId, deviceId)
        XCTAssertEqual(session.deviceName, "iPad")
    }

    func testUnknownDeviceIsRejected() throws {
        let session = makeSession()
        let challenge = try challenge(of: session)

        let outputs = session.receive(authFrame(challenge: challenge, deviceId: "unknown"))

        XCTAssertEqual(plainFrames(outputs).first?["reason"] as? String, "unknownDevice")
        XCTAssertEqual(outputs.last, .close)
        XCTAssertNil(session.deviceId)
    }

    func testWrongKeyIsRejected() throws {
        let session = makeSession()
        let challenge = try challenge(of: session)

        let outputs = session.receive(authFrame(challenge: challenge, key: SymmetricKey(size: .bits256)))

        XCTAssertEqual(plainFrames(outputs).first?["type"] as? String, "authFail")
        XCTAssertEqual(plainFrames(outputs).first?["reason"] as? String, "badMac")
        XCTAssertEqual(outputs.last, .close)
    }

    func testUnsupportedVersionIsRejected() throws {
        let session = makeSession()
        let challenge = try challenge(of: session)

        let outputs = session.receive(authFrame(challenge: challenge, version: 2))

        XCTAssertEqual(plainFrames(outputs).first?["reason"] as? String, "version")
        XCTAssertEqual(outputs.last, .close)
    }

    func testMessagesBeforeAuthCloseTheConnection() throws {
        let session = makeSession()
        _ = session.start()
        let box = try LocalBridgeWire.seal(["type": "insert", "id": "x", "text": "hi"], key: key)

        XCTAssertEqual(session.receive(box), [.close])
        XCTAssertTrue(performed.isEmpty)
    }

    // MARK: - 加密

    func testThreeConsecutiveDecryptFailuresClose() throws {
        let (session, _) = try authenticatedSession()
        let wrongKey = SymmetricKey(size: .bits256)
        let bad = try LocalBridgeWire.seal(["type": "ping", "id": "p"], key: wrongKey)

        XCTAssertEqual(session.receive(bad), [])
        XCTAssertEqual(session.receive(Data("not json".utf8)), [])
        XCTAssertEqual(session.receive(bad), [.close])
    }

    func testSuccessfulFrameResetsDecryptFailureCount() throws {
        let (session, sessionKey) = try authenticatedSession()
        let bad = try LocalBridgeWire.seal(["type": "ping", "id": "p"], key: SymmetricKey(size: .bits256))

        _ = session.receive(bad)
        _ = session.receive(bad)
        _ = session.receive(try LocalBridgeWire.seal(["type": "ping", "id": "ok"], key: sessionKey))

        XCTAssertEqual(session.receive(bad), [])
    }

    func testPairingKeyItselfIsNotTheSessionKey() throws {
        let (session, _) = try authenticatedSession()
        let sealedWithPairingKey = try LocalBridgeWire.seal(["type": "ping", "id": "p"], key: key)

        XCTAssertEqual(session.receive(sealedWithPairingKey), [])
    }

    // MARK: - insert

    func testFreshInsertIsInjectedAndAcked() throws {
        let (session, sessionKey) = try authenticatedSession()

        let ack = try sendInsert(session, sessionKey, id: "m1", text: "你好")

        XCTAssertEqual(performed, [.insert(text: "你好", then: nil)])
        XCTAssertEqual(ack["type"] as? String, "ack")
        XCTAssertEqual(ack["id"] as? String, "m1")
        XCTAssertEqual(ack["status"] as? String, "injected")
        XCTAssertEqual(ack["method"] as? String, "ax")
        XCTAssertNotNil(ack["injectMs"] as? Int)
    }

    func testInsertMethodsMapToAckMethods() throws {
        let (session, sessionKey) = try authenticatedSession()

        nextOutcome = .injected(.appleEvents)
        XCTAssertEqual(try sendInsert(session, sessionKey, id: "a")["method"] as? String, "appleEvents")
        nextOutcome = .injected(.clipboard)
        XCTAssertEqual(try sendInsert(session, sessionKey, id: "b")["method"] as? String, "clipboard")
    }

    func testInsertWithoutFocusReportsNoFocus() throws {
        let (session, sessionKey) = try authenticatedSession()
        nextOutcome = .noFocus

        let ack = try sendInsert(session, sessionKey, id: "m1")

        XCTAssertEqual(ack["status"] as? String, "noFocus")
        XCTAssertNil(ack["method"])
    }

    func testInjectionErrorReportsMessage() throws {
        let (session, sessionKey) = try authenticatedSession()
        nextOutcome = .error("没有辅助功能权限")

        let ack = try sendInsert(session, sessionKey, id: "m1")

        XCTAssertEqual(ack["status"] as? String, "error")
        XCTAssertEqual(ack["message"] as? String, "没有辅助功能权限")
    }

    func testExpiredInsertIsNotInjected() throws {
        let (session, sessionKey) = try authenticatedSession()

        let ack = try sendInsert(session, sessionKey, id: "m1",
                                 createdAt: now.timeIntervalSince1970 - 10.5, ttlMs: 10_000)

        XCTAssertEqual(ack["status"] as? String, "expired")
        XCTAssertTrue(performed.isEmpty)
    }

    func testInsertJustInsideTTLIsInjected() throws {
        let (session, sessionKey) = try authenticatedSession()

        let ack = try sendInsert(session, sessionKey, id: "m1",
                                 createdAt: now.timeIntervalSince1970 - 9.5, ttlMs: 10_000)

        XCTAssertEqual(ack["status"] as? String, "injected")
    }

    func testDuplicateIdReturnsFirstResultWithoutReinjecting() throws {
        let (session, sessionKey) = try authenticatedSession()
        _ = try sendInsert(session, sessionKey, id: "m1")

        let ack = try sendInsert(session, sessionKey, id: "m1")

        XCTAssertEqual(performed.count, 1)
        XCTAssertEqual(ack["status"] as? String, "duplicate")
        let first = try XCTUnwrap(ack["first"] as? [String: Any])
        XCTAssertEqual(first["status"] as? String, "injected")
        XCTAssertEqual(first["method"] as? String, "ax")
    }

    func testDuplicateIsDetectedAcrossSessions() throws {
        let (first, firstKey) = try authenticatedSession()
        _ = try sendInsert(first, firstKey, id: "m1")
        let (second, secondKey) = try authenticatedSession()

        let ack = try sendInsert(second, secondKey, id: "m1")

        XCTAssertEqual(ack["status"] as? String, "duplicate")
        XCTAssertEqual(performed.count, 1)
    }

    func testDuplicateOfExpiredInsertReportsExpired() throws {
        let (session, sessionKey) = try authenticatedSession()
        _ = try sendInsert(session, sessionKey, id: "m1", createdAt: now.timeIntervalSince1970 - 60)

        let ack = try sendInsert(session, sessionKey, id: "m1", createdAt: now.timeIntervalSince1970 - 60)

        XCTAssertEqual((ack["first"] as? [String: Any])?["status"] as? String, "expired")
    }

    func testInsertThenEnterIsPassedThrough() throws {
        let (session, sessionKey) = try authenticatedSession()

        _ = try sendInsert(session, sessionKey, id: "m1", text: "hi", then: "enter")

        XCTAssertEqual(performed, [.insert(text: "hi", then: .enter)])
    }

    func testInsertWithoutTextReportsError() throws {
        let (session, sessionKey) = try authenticatedSession()

        let ack = try send(session, sessionKey, ["type": "insert", "id": "m1",
                                                 "createdAt": now.timeIntervalSince1970, "ttlMs": 10_000])

        XCTAssertEqual(ack["status"] as? String, "error")
        XCTAssertTrue(performed.isEmpty)
    }

    // MARK: - key / ping

    func testKeyKindsMapToActions() throws {
        let (session, sessionKey) = try authenticatedSession()
        nextOutcome = .injected(.keyEvent)

        for (i, kind) in ["enter", "shiftEnter", "clear"].enumerated() {
            let ack = try send(session, sessionKey, ["type": "key", "id": "k\(i)", "kind": kind,
                                                     "createdAt": now.timeIntervalSince1970, "ttlMs": 10_000])
            XCTAssertEqual(ack["status"] as? String, "injected")
            XCTAssertEqual(ack["method"] as? String, "keyEvent")
        }

        XCTAssertEqual(performed, [.key(.enter), .key(.shiftEnter), .key(.clear)])
    }

    func testUnknownKeyKindReportsError() throws {
        let (session, sessionKey) = try authenticatedSession()

        let ack = try send(session, sessionKey, ["type": "key", "id": "k", "kind": "tab",
                                                 "createdAt": now.timeIntervalSince1970, "ttlMs": 10_000])

        XCTAssertEqual(ack["status"] as? String, "error")
        XCTAssertTrue(performed.isEmpty)
    }

    func testPingIsAnsweredWithPong() throws {
        let (session, sessionKey) = try authenticatedSession()

        let pong = try send(session, sessionKey, ["type": "ping", "id": "p1"])

        XCTAssertEqual(pong["type"] as? String, "pong")
        XCTAssertEqual(pong["id"] as? String, "p1")
    }

    // MARK: - Helpers

    private func plainFrames(_ outputs: [LocalBridgeSession.Output]) -> [[String: Any]] {
        outputs.compactMap {
            if case .send(let data) = $0 { return LocalBridgeWire.parse(data) }
            return nil
        }
    }

    private func challenge(of session: LocalBridgeSession) throws -> Data {
        let hello = try XCTUnwrap(plainFrames(session.start()).first)
        return try XCTUnwrap(Data(base64Encoded: hello["challenge"] as? String ?? ""))
    }

    private func authFrame(challenge: Data, deviceId: String? = nil,
                           key: SymmetricKey? = nil, version: Int = 1) -> Data {
        let device = deviceId ?? self.deviceId
        return LocalBridgeWire.json([
            "type": "auth", "v": version, "deviceId": device, "deviceName": "iPad",
            "mac": LocalBridgeWire.hmac(key: key ?? self.key, challenge: challenge, deviceId: device),
            "sentAt": now.timeIntervalSince1970,
        ])
    }

    private func authenticatedSession() throws -> (LocalBridgeSession, SymmetricKey) {
        let session = makeSession()
        let challenge = try challenge(of: session)
        let reply = plainFrames(session.receive(authFrame(challenge: challenge)))
        XCTAssertEqual(reply.first?["type"] as? String, "authOK")
        return (session, LocalBridgeWire.sessionKey(key: key, challenge: challenge))
    }

    private func send(_ session: LocalBridgeSession, _ sessionKey: SymmetricKey,
                      _ message: [String: Any]) throws -> [String: Any] {
        let outputs = session.receive(try LocalBridgeWire.seal(message, key: sessionKey))
        guard case .send(let data)? = outputs.first, let frame = LocalBridgeWire.parse(data) else {
            throw NoReply(outputs: outputs)
        }
        return try LocalBridgeWire.open(frame, key: sessionKey)
    }

    private func sendInsert(_ session: LocalBridgeSession, _ sessionKey: SymmetricKey,
                            id: String, text: String = "hello", then: String? = nil,
                            createdAt: Double? = nil, ttlMs: Int = 10_000) throws -> [String: Any] {
        var message: [String: Any] = ["type": "insert", "id": id, "round": id, "text": text,
                                      "createdAt": createdAt ?? now.timeIntervalSince1970, "ttlMs": ttlMs]
        if let then { message["then"] = then }
        return try send(session, sessionKey, message)
    }
}

private struct NoReply: Error {
    let outputs: [LocalBridgeSession.Output]
}
