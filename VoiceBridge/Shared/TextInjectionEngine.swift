import AppKit
import os

protocol TextInjectionLogging {
    func info(_ message: String)
    func warning(_ message: String)
}

struct OSLogTextInjectionLogger: TextInjectionLogging {
    let logger: Logger

    func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
    }
}

/// 注入用了哪种方式；rawValue 就是局域网回执里的 method
enum InjectionMethod: String {
    case accessibility = "ax"
    case appleEvents
    case clipboard
    case keyEvent
}

enum InjectionOutcome: Equatable {
    case injected(InjectionMethod)
    /// 没有可输入的焦点，文本或按键被丢弃
    case noFocus
    case error(String)
}

struct FocusSnapshot {

    enum State {
        case unavailable(axError: Int32)
        case nonInput(role: String?, subrole: String?, identifier: String?)
        case textInput(role: String, subrole: String?, identifier: String?, element: AXUIElement)
    }

    let frontmostBundleIdentifier: String?
    let state: State
}

protocol FocusSnapshotProviding: AnyObject {
    func currentFocusSnapshot() -> FocusSnapshot
}

protocol TextInjectionPerforming: AnyObject {
    func injectViaAccessibility(_ text: String, element: AXUIElement) -> Bool
    func injectViaAppleScript(_ text: String) -> Bool
    func injectViaClipboard(_ text: String)
    func clearViaAccessibility(_ element: AXUIElement) -> Bool
    func clearViaKeyboardShortcut()
    func pressReturnKey()
    func pressShiftReturnKey()
}

final class TextInjectionEngine {

    static let intentFallbackBundleIdentifiers: Set<String> = [
        "com.tencent.xinWeChat",
        "com.electron.lark",
    ]

    private weak var focusProvider: FocusSnapshotProviding?
    private weak var performer: TextInjectionPerforming?
    private let logger: TextInjectionLogging

    init(focusProvider: FocusSnapshotProviding,
         performer: TextInjectionPerforming,
         logger: TextInjectionLogging) {
        self.focusProvider = focusProvider
        self.performer = performer
        self.logger = logger
    }

    @discardableResult
    func inject(_ text: String) -> InjectionOutcome {
        logger.info("开始注入文本，长度: \(text.count)")

        guard let focusProvider, let performer else {
            logger.warning("依赖已释放，丢弃文本")
            return .error("注入依赖已释放")
        }

        let snapshot = focusProvider.currentFocusSnapshot()
        let frontmostApp = snapshot.frontmostBundleIdentifier ?? "?"
        let shouldUseIntentFallback = Self.intentFallbackBundleIdentifiers.contains(frontmostApp)

        switch snapshot.state {
        case .unavailable(let axError):
            logger.warning("焦点诊断 app=\(frontmostApp) 获取焦点元素失败 AXError=\(axError)")

            if shouldUseIntentFallback {
                runIntentFallback(text, app: frontmostApp, performer: performer,
                                  reason: "无法确认输入框焦点")
                return .injected(.clipboard)
            }

            logger.warning("当前无活跃输入框，丢弃文本")
            return .noFocus

        case .nonInput(let role, let subrole, let identifier):
            logger.warning("焦点诊断 app=\(frontmostApp) role=\(role ?? "nil") subrole=\(subrole ?? "nil") id=\(identifier ?? "nil") 不在白名单")
            logger.warning("当前无活跃输入框，丢弃文本")
            return .noFocus

        case .textInput(let role, let subrole, let identifier, let element):
            logger.warning("焦点诊断 app=\(frontmostApp) role=\(role) subrole=\(subrole ?? "nil") id=\(identifier ?? "nil") 命中白名单")

            if performer.injectViaAccessibility(text, element: element) {
                logger.info("Accessibility API 注入成功")
                return .injected(.accessibility)
            }

            if shouldUseIntentFallback {
                runIntentFallback(text, app: frontmostApp, performer: performer,
                                  reason: "Accessibility API 不可用")
                return .injected(.clipboard)
            }

            logger.warning("Accessibility API 失败，降级到 Apple Events")
            if performer.injectViaAppleScript(text) {
                logger.info("Apple Events 注入成功")
                return .injected(.appleEvents)
            }

            logger.warning("Apple Events 失败，降级到剪贴板")
            performer.injectViaClipboard(text)
            logger.info("剪贴板注入完成")
            return .injected(.clipboard)
        }
    }

    @discardableResult
    func pressEnter() -> InjectionOutcome {
        logger.info("开始触发回车")

        guard let focusProvider, let performer else {
            logger.warning("依赖已释放，丢弃回车事件")
            return .error("注入依赖已释放")
        }

        let snapshot = focusProvider.currentFocusSnapshot()
        let frontmostApp = snapshot.frontmostBundleIdentifier ?? "?"
        let shouldUseIntentFallback = Self.intentFallbackBundleIdentifiers.contains(frontmostApp)

        switch snapshot.state {
        case .unavailable(let axError):
            logger.warning("回车焦点诊断 app=\(frontmostApp) 获取焦点元素失败 AXError=\(axError)")

            if shouldUseIntentFallback {
                logger.warning("前台应用 \(frontmostApp) 无法确认输入框焦点，按用户意图触发回车")
                performer.pressReturnKey()
                logger.info("回车触发完成")
                return .injected(.keyEvent)
            }

            logger.warning("当前无活跃输入框，丢弃回车事件")
            return .noFocus

        case .nonInput(let role, let subrole, let identifier):
            logger.warning("回车焦点诊断 app=\(frontmostApp) role=\(role ?? "nil") subrole=\(subrole ?? "nil") id=\(identifier ?? "nil") 不在白名单")
            logger.warning("当前无活跃输入框，丢弃回车事件")
            return .noFocus

        case .textInput(let role, let subrole, let identifier, _):
            logger.warning("回车焦点诊断 app=\(frontmostApp) role=\(role) subrole=\(subrole ?? "nil") id=\(identifier ?? "nil") 命中白名单")
            performer.pressReturnKey()
            logger.info("回车触发完成")
            return .injected(.keyEvent)
        }
    }

    @discardableResult
    func pressShiftEnter() -> InjectionOutcome {
        logger.info("开始触发 Shift+回车")

        guard let focusProvider, let performer else {
            logger.warning("依赖已释放，丢弃 Shift+回车事件")
            return .error("注入依赖已释放")
        }

        let snapshot = focusProvider.currentFocusSnapshot()
        let frontmostApp = snapshot.frontmostBundleIdentifier ?? "?"
        let shouldUseIntentFallback = Self.intentFallbackBundleIdentifiers.contains(frontmostApp)

        switch snapshot.state {
        case .unavailable(let axError):
            logger.warning("Shift+回车焦点诊断 app=\(frontmostApp) 获取焦点元素失败 AXError=\(axError)")

            if shouldUseIntentFallback {
                logger.warning("前台应用 \(frontmostApp) 无法确认输入框焦点，按用户意图触发 Shift+回车")
                performer.pressShiftReturnKey()
                logger.info("Shift+回车触发完成")
                return .injected(.keyEvent)
            }

            logger.warning("当前无活跃输入框，丢弃 Shift+回车事件")
            return .noFocus

        case .nonInput(let role, let subrole, let identifier):
            logger.warning("Shift+回车焦点诊断 app=\(frontmostApp) role=\(role ?? "nil") subrole=\(subrole ?? "nil") id=\(identifier ?? "nil") 不在白名单")
            logger.warning("当前无活跃输入框，丢弃 Shift+回车事件")
            return .noFocus

        case .textInput(let role, let subrole, let identifier, _):
            logger.warning("Shift+回车焦点诊断 app=\(frontmostApp) role=\(role) subrole=\(subrole ?? "nil") id=\(identifier ?? "nil") 命中白名单")
            performer.pressShiftReturnKey()
            logger.info("Shift+回车触发完成")
            return .injected(.keyEvent)
        }
    }

    @discardableResult
    func clear() -> InjectionOutcome {
        logger.info("开始清空输入框")

        guard let focusProvider, let performer else {
            logger.warning("依赖已释放，丢弃清空事件")
            return .error("注入依赖已释放")
        }

        let snapshot = focusProvider.currentFocusSnapshot()
        let frontmostApp = snapshot.frontmostBundleIdentifier ?? "?"
        let shouldUseIntentFallback = Self.intentFallbackBundleIdentifiers.contains(frontmostApp)

        switch snapshot.state {
        case .unavailable(let axError):
            logger.warning("清空焦点诊断 app=\(frontmostApp) 获取焦点元素失败 AXError=\(axError)")

            if shouldUseIntentFallback {
                logger.warning("前台应用 \(frontmostApp) 无法确认输入框焦点，按用户意图触发清空")
                performer.clearViaKeyboardShortcut()
                logger.info("清空触发完成")
                return .injected(.keyEvent)
            }

            logger.warning("当前无活跃输入框，丢弃清空事件")
            return .noFocus

        case .nonInput(let role, let subrole, let identifier):
            logger.warning("清空焦点诊断 app=\(frontmostApp) role=\(role ?? "nil") subrole=\(subrole ?? "nil") id=\(identifier ?? "nil") 不在白名单")
            logger.warning("当前无活跃输入框，丢弃清空事件")
            return .noFocus

        case .textInput(let role, let subrole, let identifier, let element):
            logger.warning("清空焦点诊断 app=\(frontmostApp) role=\(role) subrole=\(subrole ?? "nil") id=\(identifier ?? "nil") 命中白名单")

            if performer.clearViaAccessibility(element) {
                logger.info("Accessibility API 清空成功")
                return .injected(.accessibility)
            }

            logger.warning("Accessibility API 清空失败，降级到快捷键清空")
            performer.clearViaKeyboardShortcut()
            logger.info("清空触发完成")
            return .injected(.keyEvent)
        }
    }

    private func runIntentFallback(_ text: String,
                                   app: String,
                                   performer: TextInjectionPerforming,
                                   reason: String) {
        logger.warning("前台应用 \(app) \(reason)，按用户意图走剪贴板兜底")
        performer.injectViaClipboard(text)
        logger.info("意图兜底剪贴板注入完成")
    }
}
