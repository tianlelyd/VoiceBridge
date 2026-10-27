import XCTest

@MainActor
final class PendingPairingReaperTests: XCTestCase {

    private var handshaken: Set<String> = []
    private var discarded: [String] = []

    private func makeReaper(grace: TimeInterval = 0.1) -> PendingPairingReaper {
        PendingPairingReaper(
            grace: grace,
            hasHandshaken: { [unowned self] in self.handshaken.contains($0) },
            discard: { [unowned self] in self.discarded.append($0) }
        )
    }

    private func wait(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func testDeviceThatNeverHandshakesIsDiscardedAfterGrace() async {
        let reaper = makeReaper()

        reaper.windowClosed(deviceId: "D1")
        XCTAssertEqual(discarded, [], "关窗当下不删，留时间给晚到的连接")
        await wait(0.3)

        XCTAssertEqual(discarded, ["D1"])
    }

    func testDeviceThatHandshookBeforeCloseIsKept() async {
        let reaper = makeReaper()
        handshaken.insert("D1")

        reaper.windowClosed(deviceId: "D1")
        await wait(0.3)

        XCTAssertEqual(discarded, [])
    }

    func testDeviceThatHandshakesDuringGraceIsKept() async {
        let reaper = makeReaper(grace: 0.2)

        reaper.windowClosed(deviceId: "D1")
        await wait(0.05)
        handshaken.insert("D1")
        await wait(0.4)

        XCTAssertEqual(discarded, [])
    }

    func testOnlyTheAbandonedDeviceIsDiscarded() async {
        let reaper = makeReaper()
        handshaken.insert("OLD")

        reaper.windowClosed(deviceId: "NEW")
        await wait(0.3)

        XCTAssertEqual(discarded, ["NEW"])
    }
}
