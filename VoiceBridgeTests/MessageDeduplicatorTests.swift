import XCTest

final class MessageDeduplicatorTests: XCTestCase {

    private var now = Date(timeIntervalSince1970: 1_000)

    private func makeDeduplicator<Value>(ttl: TimeInterval = 600,
                                         maxEntries: Int = 2000) -> MessageDeduplicator<Value> {
        MessageDeduplicator(ttl: ttl, maxEntries: maxEntries, clock: { [unowned self] in self.now })
    }

    func testUnknownIdIsNotRecorded() {
        let dedup: MessageDeduplicator<String> = makeDeduplicator()

        XCTAssertNil(dedup.value(for: "a"))
    }

    func testRecordedIdReturnsFirstValue() {
        let dedup: MessageDeduplicator<String> = makeDeduplicator()

        dedup.record("a", value: "first")

        XCTAssertEqual(dedup.value(for: "a"), "first")
    }

    func testEntryExpiresAfterTTL() {
        let dedup: MessageDeduplicator<String> = makeDeduplicator(ttl: 600)
        dedup.record("a", value: "first")

        now += 599
        XCTAssertEqual(dedup.value(for: "a"), "first")

        now += 2
        XCTAssertNil(dedup.value(for: "a"))
    }

    func testOldestEntriesAreEvictedBeyondCapacity() {
        let dedup: MessageDeduplicator<String> = makeDeduplicator(maxEntries: 2)

        dedup.record("a", value: "1")
        dedup.record("b", value: "2")
        dedup.record("c", value: "3")

        XCTAssertNil(dedup.value(for: "a"))
        XCTAssertEqual(dedup.value(for: "b"), "2")
        XCTAssertEqual(dedup.value(for: "c"), "3")
    }

    func testVoidDeduplicatorTracksSeenIds() {
        let dedup: MessageDeduplicator<Void> = makeDeduplicator()

        XCTAssertFalse(dedup.contains("evt"))
        dedup.record("evt")
        XCTAssertTrue(dedup.contains("evt"))
    }
}
