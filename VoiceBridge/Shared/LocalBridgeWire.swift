import CryptoKit
import Foundation
import Network

/// AIInput → VoiceBridge 局域网直连的线格式，见 docs/local-bridge-protocol.md。
/// 与 ai-input 仓库原型 MacLinkWire 兼容：握手明文 JSON，之后每帧 {"type":"box","c":<ChaChaPoly combined base64>}，
/// 加密用配对密钥和本次 challenge 派生的会话密钥。
enum LocalBridgeWire {
    static let version = 1
    static let serviceType = "_aiinput._tcp"
    static let defaultPort: UInt16 = 47800

    static func hmac(key: SymmetricKey, challenge: Data, deviceId: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: challenge + Data(deviceId.utf8), using: key)
        return Data(mac).base64EncodedString()
    }

    static func isValidHMAC(_ base64: String, key: SymmetricKey, challenge: Data, deviceId: String) -> Bool {
        guard let mac = Data(base64Encoded: base64) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: challenge + Data(deviceId.utf8), using: key)
    }

    /// 每条连接一个会话密钥：配对密钥 + 这次的 challenge 派生
    static func sessionKey(key: SymmetricKey, challenge: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: challenge,
                               info: Data("aiinput-mlink-v1".utf8), outputByteCount: 32)
    }

    static func seal(_ obj: [String: Any], key: SymmetricKey) throws -> Data {
        let plain = try JSONSerialization.data(withJSONObject: obj)
        let box = try ChaChaPoly.seal(plain, using: key)
        return try JSONSerialization.data(withJSONObject: ["type": "box", "c": box.combined.base64EncodedString()])
    }

    static func open(_ frame: [String: Any], key: SymmetricKey) throws -> [String: Any] {
        guard frame["type"] as? String == "box",
              let c = frame["c"] as? String, let data = Data(base64Encoded: c) else {
            throw CocoaError(.coderReadCorrupt)
        }
        let plain = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: data), using: key)
        guard let obj = try JSONSerialization.jsonObject(with: plain) as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        return obj
    }

    static func parse(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func json(_ obj: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    }

    /// TCP + WebSocket；客户端、服务端同一套参数
    static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 2
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        let params = NWParameters(tls: nil, tcp: tcp)
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.includePeerToPeer = false
        return params
    }

    static func send(_ data: Data, on connection: NWConnection) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "msg", metadata: [meta])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }
}
