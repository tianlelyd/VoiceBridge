import Foundation

/// 按消息 id 去重，记住每个 id 第一次的处理结果。Dictionary O(1) 查找 + Array FIFO 淘汰。
/// 飞书通道只关心见没见过（Value == Void），局域网通道要把第一次的注入结果回给重发方。
final class MessageDeduplicator<Value> {

    private let ttl: TimeInterval
    private let maxEntries: Int
    private let clock: () -> Date

    private var index: [String: (value: Value, time: Date)] = [:]
    private var queue: [(id: String, time: Date)] = []

    init(ttl: TimeInterval = 600, maxEntries: Int = 2000, clock: @escaping () -> Date = Date.init) {
        self.ttl = ttl
        self.maxEntries = maxEntries
        self.clock = clock
    }

    func value(for id: String) -> Value? {
        guard let entry = index[id], clock().timeIntervalSince(entry.time) < ttl else { return nil }
        return entry.value
    }

    func record(_ id: String, value: Value) {
        let now = clock()
        index[id] = (value, now)
        queue.append((id: id, time: now))

        let expiredCount = queue.prefix(while: { now.timeIntervalSince($0.time) > ttl }).count
        let overflow = max(queue.count - expiredCount - maxEntries, 0)
        let evictCount = expiredCount + overflow
        guard evictCount > 0 else { return }

        for entry in queue[..<evictCount] where index[entry.id]?.time == entry.time {
            index.removeValue(forKey: entry.id)
        }
        queue.removeFirst(evictCount)
    }
}

extension MessageDeduplicator where Value == Void {

    func contains(_ id: String) -> Bool {
        value(for: id) != nil
    }

    func record(_ id: String) {
        record(id, value: ())
    }
}
