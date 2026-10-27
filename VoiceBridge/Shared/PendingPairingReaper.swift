import Foundation

/// 「添加设备」窗口关掉时，这台设备要是还没握手成功过，就当作没扫码放弃了，等一小会儿再删。
/// 留宽限是因为 AIInput 扫完码可能在窗口关掉后才连上。
@MainActor
final class PendingPairingReaper {

    private let grace: TimeInterval
    private let hasHandshaken: (String) -> Bool
    private let discard: (String) -> Void

    init(grace: TimeInterval = 30,
         hasHandshaken: @escaping (String) -> Bool,
         discard: @escaping (String) -> Void) {
        self.grace = grace
        self.hasHandshaken = hasHandshaken
        self.discard = discard
    }

    func windowClosed(deviceId: String) {
        guard !hasHandshaken(deviceId) else { return }
        Task { [weak self, grace] in
            try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
            guard let self, !self.hasHandshaken(deviceId) else { return }
            self.discard(deviceId)
        }
    }
}
