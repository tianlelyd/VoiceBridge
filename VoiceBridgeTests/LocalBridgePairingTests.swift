import CryptoKit
import XCTest

// 配对可能出错的地方：二维码串手机端解不开（base64 带 +/= 不是 URL 安全、scheme 不对）；密钥不是 32 字节；
// 版本号缺失或对不上；把公司 VPN（utun 上的 10.x）、回环、链路本地地址发给手机；Tailscale 网段判断越界；
// 同一个地址重复出现；地址顺序乱（手机按顺序试）；tailscale CLI 输出读不出来时整个配对失败。
final class LocalBridgePairingTests: XCTestCase {

    private func payload(hosts: [LocalBridgeHost] = []) -> LocalBridgePairingPayload {
        LocalBridgePairingPayload(macId: "MAC-1", macName: "李的 MacBook", deviceId: "DEV-1",
                                  key: SymmetricKey(size: .bits256), port: 47800, hosts: hosts)
    }

    // MARK: - 二维码载荷

    func testPayloadRoundTripsThroughURL() throws {
        let original = payload(hosts: [LocalBridgeHost(kind: .lan, host: "mac.local"),
                                       LocalBridgeHost(kind: .tailscale, host: "100.100.1.2")])

        let decoded = try LocalBridgePairingPayload(url: original.url)

        XCTAssertEqual(decoded, original)
    }

    func testURLUsesAIInputSchemeAndURLSafeBase64() throws {
        let url = payload().url

        XCTAssertTrue(url.hasPrefix("aiinput://pair?p="), url)
        let encoded = String(url.dropFirst("aiinput://pair?p=".count))
        XCTAssertNil(encoded.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")), encoded)
    }

    func testJSONCarriesVersionKeyAndBonjourType() throws {
        let original = payload(hosts: [LocalBridgeHost(kind: .lan, host: "192.168.1.5")])

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: original.json) as? [String: Any])

        XCTAssertEqual(json["v"] as? Int, 1)
        XCTAssertEqual(json["macId"] as? String, "MAC-1")
        XCTAssertEqual(json["macName"] as? String, "李的 MacBook")
        XCTAssertEqual(json["deviceId"] as? String, "DEV-1")
        XCTAssertEqual(json["port"] as? Int, 47800)
        XCTAssertEqual(json["bonjour"] as? String, "_aiinput._tcp")
        XCTAssertEqual(Data(base64Encoded: json["key"] as? String ?? "")?.count, 32)
        XCTAssertEqual(json["hosts"] as? [[String: String]], [["kind": "lan", "host": "192.168.1.5"]])
    }

    func testDecodingRejectsOtherVersions() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload().json) as? [String: Any])
        json["v"] = 2
        let data = try JSONSerialization.data(withJSONObject: json)

        XCTAssertThrowsError(try LocalBridgePairingPayload(json: data))
    }

    func testDecodingRejectsShortKey() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload().json) as? [String: Any])
        json["key"] = Data(count: 16).base64EncodedString()
        let data = try JSONSerialization.data(withJSONObject: json)

        XCTAssertThrowsError(try LocalBridgePairingPayload(json: data))
    }

    func testDecodingRejectsForeignURL() {
        XCTAssertThrowsError(try LocalBridgePairingPayload(url: "https://example.com/pair?p=abc"))
    }

    // MARK: - 地址分类

    func testTailscaleRangeIsRecognisedOnAnyInterface() {
        XCTAssertEqual(LocalBridgeHosts.kind(ipv4: "100.101.1.2", interface: "utun4"), .tailscale)
        XCTAssertEqual(LocalBridgeHosts.kind(ipv4: "100.64.0.1", interface: "utun0"), .tailscale)
        XCTAssertEqual(LocalBridgeHosts.kind(ipv4: "100.127.255.254", interface: "utun9"), .tailscale)
    }

    func testAddressesJustOutsideTailscaleRangeAreIgnored() {
        XCTAssertNil(LocalBridgeHosts.kind(ipv4: "100.63.255.255", interface: "utun4"))
        XCTAssertNil(LocalBridgeHosts.kind(ipv4: "100.128.0.1", interface: "utun4"))
    }

    func testPrivateAddressesOnPhysicalInterfacesAreLAN() {
        XCTAssertEqual(LocalBridgeHosts.kind(ipv4: "192.168.1.5", interface: "en0"), .lan)
        XCTAssertEqual(LocalBridgeHosts.kind(ipv4: "10.0.0.8", interface: "en1"), .lan)
        XCTAssertEqual(LocalBridgeHosts.kind(ipv4: "172.20.1.1", interface: "en7"), .lan)
        XCTAssertEqual(LocalBridgeHosts.kind(ipv4: "192.168.2.1", interface: "bridge100"), .lan)
    }

    func testVPNLoopbackLinkLocalAndPublicAddressesAreIgnored() {
        XCTAssertNil(LocalBridgeHosts.kind(ipv4: "10.8.0.2", interface: "utun3"))
        XCTAssertNil(LocalBridgeHosts.kind(ipv4: "127.0.0.1", interface: "lo0"))
        XCTAssertNil(LocalBridgeHosts.kind(ipv4: "169.254.10.1", interface: "en0"))
        XCTAssertNil(LocalBridgeHosts.kind(ipv4: "172.32.0.1", interface: "en0"))
        XCTAssertNil(LocalBridgeHosts.kind(ipv4: "8.8.8.8", interface: "en0"))
        XCTAssertNil(LocalBridgeHosts.kind(ipv4: "not-an-ip", interface: "en0"))
    }

    func testHostListIsOrderedLANFirstAndDeduplicated() {
        let hosts = LocalBridgeHosts.make(
            localHostName: "Lis-MacBook",
            addresses: [("utun4", "100.101.1.2"), ("en0", "192.168.1.5"), ("utun3", "10.8.0.2"),
                        ("en0", "192.168.1.5"), ("lo0", "127.0.0.1")],
            magicDNS: "lis-macbook.tail1234.ts.net"
        )

        XCTAssertEqual(hosts, [
            LocalBridgeHost(kind: .lan, host: "Lis-MacBook.local"),
            LocalBridgeHost(kind: .lan, host: "192.168.1.5"),
            LocalBridgeHost(kind: .tailscale, host: "100.101.1.2"),
            LocalBridgeHost(kind: .tailscale, host: "lis-macbook.tail1234.ts.net"),
        ])
    }

    func testMissingHostNameAndMagicDNSAreOmitted() {
        let hosts = LocalBridgeHosts.make(localHostName: nil, addresses: [("en0", "10.0.0.8")], magicDNS: nil)

        XCTAssertEqual(hosts, [LocalBridgeHost(kind: .lan, host: "10.0.0.8")])
    }

    // MARK: - tailscale status --json

    func testMagicDNSNameIsReadFromTailscaleStatus() {
        let json = Data(#"{"Self":{"DNSName":"lis-macbook.tail1234.ts.net.","TailscaleIPs":["100.101.1.2"]}}"#.utf8)

        XCTAssertEqual(LocalBridgeHosts.magicDNSName(tailscaleStatus: json), "lis-macbook.tail1234.ts.net")
    }

    func testUnreadableTailscaleStatusGivesNoMagicDNS() {
        XCTAssertNil(LocalBridgeHosts.magicDNSName(tailscaleStatus: Data("oops".utf8)))
        XCTAssertNil(LocalBridgeHosts.magicDNSName(tailscaleStatus: Data(#"{"Self":{"DNSName":""}}"#.utf8)))
        XCTAssertNil(LocalBridgeHosts.magicDNSName(tailscaleStatus: Data(#"{"BackendState":"Stopped"}"#.utf8)))
    }
}
