import AppKit
import os

final class TextInjector {

    static let shared = TextInjector()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceBridge",
                                category: "TextInjector")

    private static let textInputRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
        "AXWebArea",
    ]

    private lazy var engine = TextInjectionEngine(focusProvider: self,
                                                  performer: self,
                                                  logger: OSLogTextInjectionLogger(logger: logger))

    private init() {}

    func inject(_ text: String) {
        engine.inject(text)
    }

    func pressEnter() {
        engine.pressEnter()
    }

    func pressShiftEnter() {
        engine.pressShiftEnter()
    }

    func clear() {
        engine.clear()
    }

    // MARK: - 获取焦点文本元素（单次查询，避免重复 IPC）

    private func focusedTextSnapshot() -> FocusSnapshot {
        let systemWide = AXUIElementCreateSystemWide()
        let appBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        var focusedRef: AnyObject?
        let copyResult = AXUIElementCopyAttributeValue(systemWide,
                                                        kAXFocusedUIElementAttribute as CFString,
                                                        &focusedRef)
        guard copyResult == .success else {
            return FocusSnapshot(frontmostBundleIdentifier: appBundle,
                                 state: .unavailable(axError: copyResult.rawValue))
        }

        let element = focusedRef as! AXUIElement

        var role: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        var subrole: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        var identifier: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &identifier)

        let roleStr = role as? String
        let subroleStr = subrole as? String
        let idStr = identifier as? String

        guard let r = roleStr, Self.textInputRoles.contains(r) else {
            return FocusSnapshot(frontmostBundleIdentifier: appBundle,
                                 state: .nonInput(role: roleStr,
                                                  subrole: subroleStr,
                                                  identifier: idStr))
        }

        return FocusSnapshot(frontmostBundleIdentifier: appBundle,
                             state: .textInput(role: r,
                                               subrole: subroleStr,
                                               identifier: idStr,
                                               element: element))
    }
}

extension TextInjector: FocusSnapshotProviding {

    func currentFocusSnapshot() -> FocusSnapshot {
        focusedTextSnapshot()
    }
}

extension TextInjector: TextInjectionPerforming {

    // MARK: - 第一层：Accessibility API

    func injectViaAccessibility(_ text: String, element: AXUIElement) -> Bool {
        // Electron / Web 视图的 AX API 返回 success 但实际不生效
        var domClass: AnyObject?
        if AXUIElementCopyAttributeValue(element,
                                         "AXDOMClassList" as CFString,
                                         &domClass) == .success {
            logger.debug("检测到 Web 视图输入框，跳过 AX 注入")
            return false
        }

        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element,
                                             kAXSelectedTextAttribute as CFString,
                                             &settable) == .success,
              settable.boolValue else {
            logger.debug("焦点元素不支持 selectedText 写入")
            return false
        }

        let result = AXUIElementSetAttributeValue(element,
                                                   kAXSelectedTextAttribute as CFString,
                                                   text as CFTypeRef)
        if result != .success {
            logger.debug("AX 设置 selectedText 失败: \(result.rawValue)")
            return false
        }

        return true
    }

    func clearViaAccessibility(_ element: AXUIElement) -> Bool {
        var domClass: AnyObject?
        if AXUIElementCopyAttributeValue(element,
                                         "AXDOMClassList" as CFString,
                                         &domClass) == .success {
            logger.debug("检测到 Web 视图输入框，跳过 AX 清空")
            return false
        }

        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element,
                                             kAXValueAttribute as CFString,
                                             &settable) == .success,
              settable.boolValue else {
            logger.debug("焦点元素不支持 value 写入")
            return false
        }

        let result = AXUIElementSetAttributeValue(element,
                                                  kAXValueAttribute as CFString,
                                                  "" as CFTypeRef)
        if result != .success {
            logger.debug("AX 设置 value 失败: \(result.rawValue)")
            return false
        }

        return true
    }

    // MARK: - 第二层：Apple Events

    func injectViaAppleScript(_ text: String) -> Bool {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")

        let source = """
        tell application "System Events"
            keystroke "\(escaped)"
        end tell
        """

        guard let script = NSAppleScript(source: source) else { return false }

        var error: NSDictionary?
        script.executeAndReturnError(&error)

        if let error = error {
            logger.error("AppleScript 执行失败: \(error)")
            return false
        }
        return true
    }

    // MARK: - 第三层：剪贴板 + Cmd+V

    func injectViaClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general

        // 保存原剪贴板（所有类型）
        let previousItems = pasteboard.pasteboardItems?.map { item -> NSPasteboardItem in
            let newItem = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    newItem.setData(data, forType: type)
                }
            }
            return newItem
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        simulatePaste()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            pasteboard.clearContents()
            if let items = previousItems {
                pasteboard.writeObjects(items)
            }
        }
    }

    private func simulatePaste() {
        postKey(virtualKey: 0x09, flags: .maskCommand)
    }

    func clearViaKeyboardShortcut() {
        postKey(virtualKey: 0x00, flags: .maskCommand)
        postKey(virtualKey: 0x33)
    }

    func pressReturnKey() {
        postKey(virtualKey: 0x24)
    }

    func pressShiftReturnKey() {
        postKey(virtualKey: 0x24, flags: .maskShift)
    }

    private func postKey(virtualKey: CGKeyCode, flags: CGEventFlags = CGEventFlags()) {
        let source = CGEventSource(stateID: .hidSystemState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: true)
        keyDown?.flags = flags
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: false)
        keyUp?.flags = flags
        keyUp?.post(tap: .cghidEventTap)
    }
}
