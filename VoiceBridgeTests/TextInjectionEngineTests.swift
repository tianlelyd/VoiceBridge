import XCTest

final class TextInjectionEngineTests: XCTestCase {

    func testWeChatUnavailableFocusFallsBackToClipboard() {
        let recorder = RecordingPerformer()
        let engine = makeEngine(snapshot: FocusSnapshot(
            frontmostBundleIdentifier: "com.tencent.xinWeChat",
            state: .unavailable(axError: -25212)
        ), performer: recorder)

        engine.inject("hello")

        XCTAssertEqual(recorder.calls, [.clipboard("hello")])
    }

    func testFeishuUnavailableFocusFallsBackToClipboard() {
        let recorder = RecordingPerformer()
        let engine = makeEngine(snapshot: FocusSnapshot(
            frontmostBundleIdentifier: "com.electron.lark",
            state: .unavailable(axError: -25212)
        ), performer: recorder)

        engine.inject("hello")

        XCTAssertEqual(recorder.calls, [.clipboard("hello")])
    }

    func testNonWhitelistedUnavailableFocusDropsText() {
        let recorder = RecordingPerformer()
        let engine = makeEngine(snapshot: FocusSnapshot(
            frontmostBundleIdentifier: "com.apple.dt.Xcode",
            state: .unavailable(axError: -25212)
        ), performer: recorder)

        engine.inject("hello")

        XCTAssertTrue(recorder.calls.isEmpty)
    }

    func testNonInputFocusDropsText() {
        let recorder = RecordingPerformer()
        let engine = makeEngine(snapshot: FocusSnapshot(
            frontmostBundleIdentifier: "com.apple.dt.Xcode",
            state: .nonInput(role: "AXButton", subrole: "AXSwitch", identifier: "foo")
        ), performer: recorder)

        engine.inject("hello")

        XCTAssertTrue(recorder.calls.isEmpty)
    }

    func testNativeTextInputStopsAfterSuccessfulAccessibilityInjection() {
        let recorder = RecordingPerformer(accessibilityResult: true)
        let engine = makeEngine(snapshot: FocusSnapshot(
            frontmostBundleIdentifier: "com.apple.dt.Xcode",
            state: .textInput(role: "AXTextArea", subrole: nil, identifier: "source",
                              element: AXUIElementCreateSystemWide())
        ), performer: recorder)

        engine.inject("hello")

        XCTAssertEqual(recorder.calls, [.accessibility("hello")])
    }

    func testNativeTextInputFallsBackToAppleScriptThenClipboard() {
        let recorder = RecordingPerformer(accessibilityResult: false, appleScriptResult: false)
        let engine = makeEngine(snapshot: FocusSnapshot(
            frontmostBundleIdentifier: "com.apple.dt.Xcode",
            state: .textInput(role: "AXTextArea", subrole: nil, identifier: "source",
                              element: AXUIElementCreateSystemWide())
        ), performer: recorder)

        engine.inject("hello")

        XCTAssertEqual(recorder.calls, [
            .accessibility("hello"),
            .appleScript("hello"),
            .clipboard("hello"),
        ])
    }

    func testNativeTextInputStopsAfterAppleScriptSuccess() {
        let recorder = RecordingPerformer(accessibilityResult: false, appleScriptResult: true)
        let engine = makeEngine(snapshot: FocusSnapshot(
            frontmostBundleIdentifier: "com.apple.dt.Xcode",
            state: .textInput(role: "AXTextArea", subrole: nil, identifier: "source",
                              element: AXUIElementCreateSystemWide())
        ), performer: recorder)

        engine.inject("hello")

        XCTAssertEqual(recorder.calls, [
            .accessibility("hello"),
            .appleScript("hello"),
        ])
    }

    func testFeishuTextInputSkipsAppleScriptAndUsesClipboardFallback() {
        let recorder = RecordingPerformer(accessibilityResult: false, appleScriptResult: false)
        let engine = makeEngine(snapshot: FocusSnapshot(
            frontmostBundleIdentifier: "com.electron.lark",
            state: .textInput(role: "AXTextArea", subrole: nil, identifier: "chat",
                              element: AXUIElementCreateSystemWide())
        ), performer: recorder)

        engine.inject("hello")

        XCTAssertEqual(recorder.calls, [
            .accessibility("hello"),
            .clipboard("hello"),
        ])
    }

    func testTextInputEnterPressesReturnKey() {
        let recorder = RecordingPerformer()
        let engine = makeEngine(snapshot: FocusSnapshot(
            frontmostBundleIdentifier: "com.apple.TextEdit",
            state: .textInput(role: "AXTextArea", subrole: nil, identifier: "document",
                              element: AXUIElementCreateSystemWide())
        ), performer: recorder)

        engine.pressEnter()

        XCTAssertEqual(recorder.calls, [.returnKey])
    }

    func testIntentFallbackUnavailableEnterPressesReturnKey() {
        let recorder = RecordingPerformer()
        let engine = makeEngine(snapshot: FocusSnapshot(
            frontmostBundleIdentifier: "com.electron.lark",
            state: .unavailable(axError: -25212)
        ), performer: recorder)

        engine.pressEnter()

        XCTAssertEqual(recorder.calls, [.returnKey])
    }

    func testNonInputEnterDropsEvent() {
        let recorder = RecordingPerformer()
        let engine = makeEngine(snapshot: FocusSnapshot(
            frontmostBundleIdentifier: "com.apple.dt.Xcode",
            state: .nonInput(role: "AXButton", subrole: "AXSwitch", identifier: "foo")
        ), performer: recorder)

        engine.pressEnter()

        XCTAssertTrue(recorder.calls.isEmpty)
    }

    func testTextInputShiftEnterPressesShiftReturnKey() {
        let recorder = RecordingPerformer()
        let engine = makeEngine(snapshot: FocusSnapshot(
            frontmostBundleIdentifier: "com.apple.TextEdit",
            state: .textInput(role: "AXTextArea", subrole: nil, identifier: "document",
                              element: AXUIElementCreateSystemWide())
        ), performer: recorder)

        engine.pressShiftEnter()

        XCTAssertEqual(recorder.calls, [.shiftReturnKey])
    }

    func testIntentFallbackUnavailableShiftEnterPressesShiftReturnKey() {
        let recorder = RecordingPerformer()
        let engine = makeEngine(snapshot: FocusSnapshot(
            frontmostBundleIdentifier: "com.electron.lark",
            state: .unavailable(axError: -25212)
        ), performer: recorder)

        engine.pressShiftEnter()

        XCTAssertEqual(recorder.calls, [.shiftReturnKey])
    }

    func testNonInputShiftEnterDropsEvent() {
        let recorder = RecordingPerformer()
        let engine = makeEngine(snapshot: FocusSnapshot(
            frontmostBundleIdentifier: "com.apple.dt.Xcode",
            state: .nonInput(role: "AXButton", subrole: "AXSwitch", identifier: "foo")
        ), performer: recorder)

        engine.pressShiftEnter()

        XCTAssertTrue(recorder.calls.isEmpty)
    }

    func testTextInputClearUsesAccessibilityWhenAvailable() {
        let recorder = RecordingPerformer(clearAccessibilityResult: true)
        let engine = makeEngine(snapshot: FocusSnapshot(
            frontmostBundleIdentifier: "com.apple.TextEdit",
            state: .textInput(role: "AXTextArea", subrole: nil, identifier: "document",
                              element: AXUIElementCreateSystemWide())
        ), performer: recorder)

        engine.clear()

        XCTAssertEqual(recorder.calls, [.clearAccessibility])
    }

    func testTextInputClearFallsBackToKeyboardShortcut() {
        let recorder = RecordingPerformer(clearAccessibilityResult: false)
        let engine = makeEngine(snapshot: FocusSnapshot(
            frontmostBundleIdentifier: "com.apple.TextEdit",
            state: .textInput(role: "AXTextArea", subrole: nil, identifier: "document",
                              element: AXUIElementCreateSystemWide())
        ), performer: recorder)

        engine.clear()

        XCTAssertEqual(recorder.calls, [.clearAccessibility, .clearKeyboardShortcut])
    }

    func testIntentFallbackUnavailableClearUsesKeyboardShortcut() {
        let recorder = RecordingPerformer()
        let engine = makeEngine(snapshot: FocusSnapshot(
            frontmostBundleIdentifier: "com.electron.lark",
            state: .unavailable(axError: -25212)
        ), performer: recorder)

        engine.clear()

        XCTAssertEqual(recorder.calls, [.clearKeyboardShortcut])
    }

    func testNonInputClearDropsEvent() {
        let recorder = RecordingPerformer()
        let engine = makeEngine(snapshot: FocusSnapshot(
            frontmostBundleIdentifier: "com.apple.dt.Xcode",
            state: .nonInput(role: "AXButton", subrole: "AXSwitch", identifier: "foo")
        ), performer: recorder)

        engine.clear()

        XCTAssertTrue(recorder.calls.isEmpty)
    }

    // 引擎内部对 focusProvider/performer 用 weak，测试需在测例生命周期里持有它们
    private var providers: [StaticFocusProvider] = []
    private var performers: [RecordingPerformer] = []

    override func tearDown() {
        providers.removeAll()
        performers.removeAll()
        super.tearDown()
    }

    private func makeEngine(snapshot: FocusSnapshot,
                            performer: RecordingPerformer) -> TextInjectionEngine {
        let provider = StaticFocusProvider(snapshot: snapshot)
        providers.append(provider)
        performers.append(performer)
        return TextInjectionEngine(
            focusProvider: provider,
            performer: performer,
            logger: NoOpLogger()
        )
    }
}

private final class StaticFocusProvider: FocusSnapshotProviding {

    private let snapshot: FocusSnapshot

    init(snapshot: FocusSnapshot) {
        self.snapshot = snapshot
    }

    func currentFocusSnapshot() -> FocusSnapshot {
        snapshot
    }
}

private final class RecordingPerformer: TextInjectionPerforming {

    enum Call: Equatable {
        case accessibility(String)
        case appleScript(String)
        case clipboard(String)
        case returnKey
        case shiftReturnKey
        case clearAccessibility
        case clearKeyboardShortcut
    }

    private let accessibilityResult: Bool
    private let appleScriptResult: Bool
    private let clearAccessibilityResult: Bool

    private(set) var calls: [Call] = []

    init(accessibilityResult: Bool = false,
         appleScriptResult: Bool = false,
         clearAccessibilityResult: Bool = false) {
        self.accessibilityResult = accessibilityResult
        self.appleScriptResult = appleScriptResult
        self.clearAccessibilityResult = clearAccessibilityResult
    }

    func injectViaAccessibility(_ text: String, element: AXUIElement) -> Bool {
        calls.append(.accessibility(text))
        return accessibilityResult
    }

    func injectViaAppleScript(_ text: String) -> Bool {
        calls.append(.appleScript(text))
        return appleScriptResult
    }

    func injectViaClipboard(_ text: String) {
        calls.append(.clipboard(text))
    }

    func clearViaAccessibility(_ element: AXUIElement) -> Bool {
        calls.append(.clearAccessibility)
        return clearAccessibilityResult
    }

    func clearViaKeyboardShortcut() {
        calls.append(.clearKeyboardShortcut)
    }

    func pressReturnKey() {
        calls.append(.returnKey)
    }

    func pressShiftReturnKey() {
        calls.append(.shiftReturnKey)
    }
}

private struct NoOpLogger: TextInjectionLogging {
    func info(_ message: String) {}
    func warning(_ message: String) {}
}
