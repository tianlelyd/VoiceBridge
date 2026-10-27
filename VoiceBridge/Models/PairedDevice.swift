import Foundation

/// 通过局域网直连的手机/平板。配对密钥存 Keychain，这里只放元数据
struct PairedDevice: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    let pairedAt: Date
    var lastSeenAt: Date?

    var keychainKey: String { "local-bridge-device-\(id)" }
}
