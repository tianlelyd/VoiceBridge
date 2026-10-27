import XCTest

final class TextInjectionEngineTests: XCTestCase {

    func testWeChatUnavailableFocusFallsBackToClipboard() {
        let recorder = RecordingPerformer()
        let engine = makeEngine(snapshot: FocusSnapshot(
            frontmostBundleIdentifier: "com.tencent.xinWeChat",
            state: .unavailable(axError: -25212)
        ), performer: recorder)

        let outcome = engine.inject("hello")

        XCTAssertEqual(recorder.calls, [.clipboard("hello")])
        XCTAssertEqual(outcome, .injected(.clipboard))
    }

    func testFeishuUnavailableFocusFallsBackToClipboard() {
        let recorder = RecordingPerformer()
        let engine = makeEngine(snapshot: FocusSnapshot(
            frontmostBundleIdentifier: "com.electron.lark",
            state: .unavailable(axError: -25212)
        ), performer: recorder)

        let outcome = engine.inject("hello")

        XCTAssertEqual(recorder.calls, [.clipboard("hello")])
        XCTAssertEqual(outcome, .injected(.clipboard))
    }

    func testNonWhitelistedUnavailableFocusDropsText() {
        let recorder = RecordingPerformer()
        let engine = makeEngine(snapshot: FocusSnapshot(
            frontmostBundleIdentifier: "com.apple.dt.Xcode",
            state: .unavailable(axError: -25212)
        ), performer: recorder)

        let outcome = engine.inject("hello")

        XCTAssertTrue(recorder.calls.isEmpty)
        XCTAssertEqual(outcome, .noFocus)
    }

    func testNonInputFocusDropsText() {
        let recorder = RecordingPerformer()
        let engine = makeEngine(snapshot: FocusSnapshot(
            frontmostBundleIdentifier: "com.apple.dt.Xcode",
            state: .nonInput(role: "AXButton", subrole: "AXSwitch", identifier: "foo")
        ), performer: recorder)

        let outcome = engine.inject("hello")

        XCTAssertTrue(recorder.calls.isEmpty)
        XCTAssertEqual(outcome, .noFocus)
    }

    func testNativeTextInputStopsAfterSuccessfulAccessibilityInjection() {
        let recorder = RecordingPerformer(accessibilityResult: true)
        let engine = makeEngine(snapshot: FocusSnapshot(
            frontmostBundleIdentifier: "com.apple.dt.Xcode",
            state: .textInput(role: "AXTextArea", subrole: nil, identifier: "source",
                              element: AXUIElementCreateSystemWide())
        ), performer: recorder)

        let outcome = engine.inject("hello")

        XCTAssertEqual(recorder.calls, [.accessibility("hello")])
        XCTAssertEqual(outcome, .injected(.accessibility))
    }

    func testNativeTextInputFallsBackToAppleScriptThenClipboard() {
        let recorder = RecordingPerformer(accessibilityResult: false, appleScriptResult: false)
        let engine = makeEngine(snapshot: FocusSnapshot(
            frontmostBundleIdentifier: "com.apple.dt.Xcode",
            state: .textInput(role: "AXTextArea", subrole: nil, identifier: "source",
                              element: AXUIElementCreateSystemWide())
        ), performer: recorder)

        let outcome = engine.inject("hello")

        XCTAssertEqual(recorder.calls, [
            .accessibility("hello"),
            .appleScript("hello"),
            .clipboard("hello"),
        ])
        XCTAssertEqual(outcome, .injected(.clipboard))
    }

    func testNativeTextInputStopsAfterAppleScriptSuccess() {
        let recorder = RecordingPerformer(accessibilityResult: false, appleScriptResult: true)
        let engine = makeEngine(snapshot: FocusSnapshot(
            frontmostBundleIdentifier: "com.apple.dt.Xcode",
            state: .textInput(role: "AXTextArea", subrole: nil, identifier: "source",
                              element: AXUIElementCreateSystemWide())
        ), performer: recorder)

        let outcome = engine.inject("hello")

        XCTAssertEqual(recorder.calls, [
            .accessibility("hello"),
            .appleScript("hello"),
        ])
        XCTAssertEqual(outcome, .injected(.appleEvents))
    }

    func testFeishuTextInputSkipsAppleScriptAndUsesClipboardFallback() {
        let recorder = RecordingPerformer(accessibilityResult: false, appleScriptResult: false)
        let engine = makeEngine(snapshot: FocusSnapshot(
            frontmostBundleIdentifier: "com.electron.lark",
            state: .textInput(role: "AXTextArea", subrole: nil, identifier: "chat",
                              element: AXUIElementCreateSystemWide())
        ), performer: recorder)

        let outcome = engine.inject("hello")

        XCTAssertEqual(recorder.calls, [
            .accessibility("hello"),
            .clipboard("hello"),
        ])
        XCTAssertEqual(outcome, .injected(.clipboard))
    }

    func testTextInputEnterPressesReturnKey() {
        let recorder = RecordingPerformer()
        let engine = makeEngine(snapshot: FocusSnapshot(
            frontmostBundleIdentifier: "com.apple.TextEdit",
            state: .textInput(role: "AXTextArea", subrole: nil, identifier: "document",
                              element: AXUIElementCreateSystemWide())
        ), performer: recorder)

        let outcome = engine.pressEnter()

        XCTAssertEqual(recorder.calls, [.returnKey])
        XCTAssertEqual(outcome, .injected(.keyEvent))
    }

    func testIntentFallbackUnavailableEnterPressesReturnKey() {
        let recorder = RecordingPerformer()
        let engine = makeEngine(snapshot: FocusSnapshot(
            frontmostBundleIdentifier: "com.electron.lark",
            state: .unavailable(axError: -25212)
        ), performer: recorder)

        let outcome = engine.pressEnter()

        XCTAssertEqual(recorder.calls, [.returnKey])
        XCTAssertEqual(outcome, .injected(.keyEvent))
    }

    func testNonInputEnterDropsEvent() {
        let recorder = RecordingPerformer()
        let engine = makeEngine(snapshot: FocusSnapshot(
            frontmostBundleIdentifier: "com.apple.dt.Xcode",
            state: .nonInput(role: "AXButton", subrole: "AXSwitch", identifier: "foo")
        ), performer: recorder)

        let outcome = engine.pressEnter()

        XCTAssertTrue(recorder.calls.isEmpty)
        XCTAssertEqual(outcome, .noFocus)
    }

    func testTextInputShiftEnterPressesShiftReturnKey() {
        let recorder = RecordingPerformer()
        let engine = makeEngine(snapshot: FocusSnapshot(
            frontmostBundleIdentifier: "com.apple.TextEdit",
            state: .textInput(role: "AXTextArea", subrole: nil, identifier: "document",
                              element: AXUIElementCreateSystemWide())
        ), performer: recorder)

        let outcome = engine.pressShiftEnter()

        XCTAssertEqual(recorder.calls, [.shiftReturnKey])
        XCTAssertEqual(outcome, .injected(.keyEvent))
    }

    func testIntentFallbackUnavailableShiftEnterPressesShiftReturnKey() {
        let recorder = RecordingPerformer()
        let engine = makeEngine(snapshot: FocusSnapshot(
            frontmostBundleIdentifier: "com.electron.lark",
            state: .unavailable(axError: -25212)
        ), performer: recorder)

        let outcome = engine.pressShiftEnter()

        XCTAssertEqual(recorder.calls, [.shiftReturnKey])
        XCTAssertEqual(outcome, .injected(.keyEvent))
    }

    func testNonInputShiftEnterDropsEvent() {
        let recorder = RecordingPerformer()
        let engine = makeEngine(snapshot: FocusSnapshot(
            frontmostBundleIdentifier: "com.apple.dt.Xcode",
            state: .nonInput(role: "AXButton", subrole: "AXSwitch", identifier: "foo")
        ), performer: recorder)

        let outcome = engine.pressShiftEnter()

        XCTAssertTrue(recorder.calls.isEmpty)
        XCTAssertEqual(outcome, .noFocus)
    }

    func testTextInputClearUsesAccessibilityWhenAvailable() {
        let recorder = RecordingPerformer(clearAccessibilityResult: true)
        let engine = makeEngine(snapshot: FocusSnapshot(
            frontmostBundleIdentifier: "com.apple.TextEdit",
            state: .textInput(role: "AXTextArea", subrole: nil, identifier: "document",
                              element: AXUIElementCreateSystemWide())
        ), performer: recorder)

        let outcome = engine.clear()

        XCTAssertEqual(recorder.calls, [.clearAccessibility])
        XCTAssertEqual(outcome, .injected(.accessibility))
    }

    func testTextInputClearFallsBackToKeyboardShortcut() {
        let recorder = RecordingPerformer(clearAccessibilityResult: false)
        let engine = makeEngine(snapshot: FocusSnapshot(
            frontmostBundleIdentifier: "com.apple.TextEdit",
            state: .textInput(role: "AXTextArea", subrole: nil, identifier: "document",
                              element: AXUIElementCreateSystemWide())
        ), performer: recorder)

        let outcome = engine.clear()

        XCTAssertEqual(recorder.calls, [.clearAccessibility, .clearKeyboardShortcut])
        XCTAssertEqual(outcome, .injected(.keyEvent))
    }

    func testIntentFallbackUnavailableClearUsesKeyboardShortcut() {
        let recorder = RecordingPerformer()
        let engine = makeEngine(snapshot: FocusSnapshot(
            frontmostBundleIdentifier: "com.electron.lark",
            state: .unavailable(axError: -25212)
        ), performer: recorder)

        let outcome = engine.clear()

        XCTAssertEqual(recorder.calls, [.clearKeyboardShortcut])
        XCTAssertEqual(outcome, .injected(.keyEvent))
    }

    func testNonInputClearDropsEvent() {
        let recorder = RecordingPerformer()
        let engine = makeEngine(snapshot: FocusSnapshot(
            frontmostBundleIdentifier: "com.apple.dt.Xcode",
            state: .nonInput(role: "AXButton", subrole: "AXSwitch", identifier: "foo")
        ), performer: recorder)

        let outcome = engine.clear()

        XCTAssertTrue(recorder.calls.isEmpty)
        XCTAssertEqual(outcome, .noFocus)
    }

    func testReleasedDependenciesReportError() {
        var provider: StaticFocusProvider? = StaticFocusProvider(snapshot: FocusSnapshot(
            frontmostBundleIdentifier: "com.apple.TextEdit",
            state: .nonInput(role: nil, subrole: nil, identifier: nil)
        ))
        let performer = RecordingPerformer()
        let engine = TextInjectionEngine(focusProvider: provider!, performer: performer, logger: NoOpLogger())
        provider = nil

        guard case .error = engine.inject("hello") else {
            return XCTFail("依赖释放后应返回 error")
        }
    }

    // 引擎内部对 focusProvider/performer 用 weak，测试需在测例生命周期里持有它们
    private var providers: [StaticFocusProvider] = []
    private var performers: [RecordingPerformer] = []

    override func tearDown() {
        providers.removeAll()
        performers.removeAll()
        super.tearDown()
    }

    // MARK: - 焦点诊断日志

    func testDiagnosticNamesAppWithoutBundleIdentifier() {
        let logger = RecordingLogger()
        let engine = makeEngine(snapshot: FocusSnapshot(
            frontmostBundleIdentifier: nil,
            state: .nonInput(role: "AXWindow", subrole: nil, identifier: nil),
            frontmostAppName: "e2e-window"
        ), performer: RecordingPerformer(), logger: logger)

        engine.inject("hello")

        XCTAssertTrue(logger.warnings.contains { $0.contains("app=e2e-window ") }, "\(logger.warnings)")
    }

    func testDiagnosticShowsAppNameAndBundleIdentifier() {
        let logger = RecordingLogger()
        let engine = makeEngine(snapshot: FocusSnapshot(
            frontmostBundleIdentifier: "com.apple.dt.Xcode",
            state: .unavailable(axError: -25212),
            frontmostAppName: "Xcode"
        ), performer: RecordingPerformer(), logger: logger)

        engine.pressEnter()

        XCTAssertTrue(logger.warnings.contains { $0.contains("app=Xcode(com.apple.dt.Xcode) ") }, "\(logger.warnings)")
    }

    private func makeEngine(snapshot: FocusSnapshot,
                            performer: RecordingPerformer,
                            logger: TextInjectionLogging = NoOpLogger()) -> TextInjectionEngine {
        let provider = StaticFocusProvider(snapshot: snapshot)
        providers.append(provider)
        performers.append(performer)
        return TextInjectionEngine(
            focusProvider: provider,
            performer: performer,
            logger: logger
        )
    }
}

private final class RecordingLogger: TextInjectionLogging {
    private(set) var warnings: [String] = []
    func info(_ message: String) {}
    func warning(_ message: String) { warnings.append(message) }
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
