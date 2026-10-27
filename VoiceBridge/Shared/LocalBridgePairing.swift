import CryptoKit
import Foundation

/// 手机直连 Mac 的候选地址，手机按顺序尝试
struct LocalBridgeHost: Equatable, Hashable {

    enum Kind: String {
        case lan
        case tailscale
    }

    let kind: Kind
    let host: String

    var fields: [String: String] { ["kind": kind.rawValue, "host": host] }
}

/// 配对二维码载荷，格式见 docs/local-bridge-protocol.md
struct LocalBridgePairingPayload: Equatable {

    struct DecodeError: Error {}

    static let urlPrefix = "aiinput://pair?p="

    let macId: String
    let macName: String
    let deviceId: String
    let key: SymmetricKey
    let port: UInt16
    let hosts: [LocalBridgeHost]

    /// 二维码内容
    var url: String { Self.urlPrefix + json.base64URLEncodedString() }

    var json: Data {
        LocalBridgeWire.json([
            "v": LocalBridgeWire.version,
            "macId": macId,
            "macName": macName,
            "deviceId": deviceId,
            "key": key.withUnsafeBytes { Data($0) }.base64EncodedString(),
            "port": Int(port),
            "bonjour": LocalBridgeWire.serviceType,
            "hosts": hosts.map(\.fields),
        ])
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.macId == rhs.macId && lhs.macName == rhs.macName && lhs.deviceId == rhs.deviceId
            && lhs.key == rhs.key && lhs.port == rhs.port && lhs.hosts == rhs.hosts
    }
}

extension LocalBridgePairingPayload {

    init(json data: Data) throws {
        guard let obj = LocalBridgeWire.parse(data),
              obj["v"] as? Int == LocalBridgeWire.version,
              let macId = obj["macId"] as? String,
              let macName = obj["macName"] as? String,
              let deviceId = obj["deviceId"] as? String,
              let keyData = Data(base64Encoded: obj["key"] as? String ?? ""), keyData.count == 32,
              let port = obj["port"] as? Int, let port = UInt16(exactly: port) else {
            throw DecodeError()
        }
        let hosts = (obj["hosts"] as? [[String: String]] ?? []).compactMap { entry -> LocalBridgeHost? in
            guard let kind = entry["kind"].flatMap(LocalBridgeHost.Kind.init(rawValue:)),
                  let host = entry["host"] else { return nil }
            return LocalBridgeHost(kind: kind, host: host)
        }
        self.init(macId: macId, macName: macName, deviceId: deviceId,
                  key: SymmetricKey(data: keyData), port: port, hosts: hosts)
    }

    init(url: String) throws {
        guard url.hasPrefix(Self.urlPrefix),
              let data = Data(base64URLEncoded: String(url.dropFirst(Self.urlPrefix.count))) else {
            throw DecodeError()
        }
        try self.init(json: data)
    }
}

/// 收集本机能给手机直连的地址：局域网主机名/IP，Tailscale 100.x 和 MagicDNS 名
enum LocalBridgeHosts {

    /// 只认硬件网卡（SystemConfiguration 的硬件端口：Wi-Fi、以太网、雷雳网桥）上的私网地址和任意网卡上的 Tailscale 网段。
    /// 虚拟机/容器的 bridge100+、vmnet*、vnic*，其他 VPN、回环、链路本地一律不要
    static func kind(ipv4: String, interface: String, hardwareInterfaces: Set<String>) -> LocalBridgeHost.Kind? {
        let parts = ipv4.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return nil }
        let (a, b) = (parts[0], parts[1])

        if a == 100, (64...127).contains(b) { return .tailscale }

        let isPrivate = a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168)
        return isPrivate && hardwareInterfaces.contains(interface) ? .lan : nil
    }

    static func make(localHostName: String?, addresses: [(interface: String, ipv4: String)],
                     hardwareInterfaces: Set<String>, magicDNS: String?) -> [LocalBridgeHost] {
        var lan: [LocalBridgeHost] = []
        var tailscale: [LocalBridgeHost] = []
        if let localHostName, !localHostName.isEmpty {
            lan.append(LocalBridgeHost(kind: .lan, host: "\(localHostName).local"))
        }
        for (interface, ipv4) in addresses {
            switch kind(ipv4: ipv4, interface: interface, hardwareInterfaces: hardwareInterfaces) {
            case .lan: lan.append(LocalBridgeHost(kind: .lan, host: ipv4))
            case .tailscale: tailscale.append(LocalBridgeHost(kind: .tailscale, host: ipv4))
            case nil: break
            }
        }
        if let magicDNS, !magicDNS.isEmpty {
            tailscale.append(LocalBridgeHost(kind: .tailscale, host: magicDNS))
        }

        var seen = Set<LocalBridgeHost>()
        return (lan + tailscale).filter { seen.insert($0).inserted }
    }

    /// 解析 `tailscale status --json` 的 Self.DNSName，去掉末尾的点
    nonisolated static func magicDNSName(tailscaleStatus data: Data) -> String? {
        guard let obj = LocalBridgeWire.parse(data),
              let me = obj["Self"] as? [String: Any],
              let name = me["DNSName"] as? String else { return nil }
        let trimmed = name.hasSuffix(".") ? String(name.dropLast()) : name
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension Data {

    init?(base64URLEncoded string: String) {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
