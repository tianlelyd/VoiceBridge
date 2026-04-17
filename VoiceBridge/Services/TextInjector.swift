import AppKit
import os

final class TextInjector {

    static let shared = TextInjector()
    private static let intentFallbackBundleIdentifiers: Set<String> = [
        "com.tencent.xinWeChat",
        "com.electron.lark",
    ]

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VoiceBridge",
                                category: "TextInjector")

    private static let textInputRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
        "AXWebArea",
    ]

    private init() {}

    func inject(_ text: String) {
        logger.info("开始注入文本，长度: \(text.count)")
        let frontmostApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        let shouldUseIntentFallback = Self.intentFallbackBundleIdentifiers.contains(frontmostApp)

        guard let element = focusedTextElement() else {
            if shouldUseIntentFallback {
                logger.warning("前台应用 \(frontmostApp, privacy: .public) 无法确认输入框焦点，按用户意图走剪贴板兜底")
                injectViaClipboard(text)
                logger.info("意图兜底剪贴板注入完成")
                return
            }

            logger.warning("当前无活跃输入框，丢弃文本")
            return
        }

        if injectViaAccessibility(text, element: element) {
            logger.info("Accessibility API 注入成功")
            return
        }

        if shouldUseIntentFallback {
            logger.warning("前台应用 \(frontmostApp, privacy: .public) 下 Accessibility API 不可用，直接降级到剪贴板")
            injectViaClipboard(text)
            logger.info("意图兜底剪贴板注入完成")
            return
        }

        logger.warning("Accessibility API 失败，降级到 Apple Events")
        if injectViaAppleScript(text) {
            logger.info("Apple Events 注入成功")
            return
        }

        logger.warning("Apple Events 失败，降级到剪贴板")
        injectViaClipboard(text)
        logger.info("剪贴板注入完成")
    }

    // MARK: - 获取焦点文本元素（单次查询，避免重复 IPC）

    private func focusedTextElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        let appBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"

        var focusedRef: AnyObject?
        let copyResult = AXUIElementCopyAttributeValue(systemWide,
                                                        kAXFocusedUIElementAttribute as CFString,
                                                        &focusedRef)
        guard copyResult == .success else {
            logger.warning("焦点诊断 app=\(appBundle, privacy: .public) 获取焦点元素失败 AXError=\(copyResult.rawValue)")
            return nil
        }

        // AXUIElement is a CFTypeRef, always succeeds from AX API
        let element = focusedRef as! AXUIElement

        var role: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        var subrole: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        var identifier: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &identifier)

        let roleStr = (role as? String) ?? "nil"
        let subroleStr = (subrole as? String) ?? "nil"
        let idStr = (identifier as? String) ?? "nil"

        guard let r = role as? String, Self.textInputRoles.contains(r) else {
            logger.warning("焦点诊断 app=\(appBundle, privacy: .public) role=\(roleStr, privacy: .public) subrole=\(subroleStr, privacy: .public) id=\(idStr, privacy: .public) 不在白名单")
            return nil
        }

        logger.warning("焦点诊断 app=\(appBundle, privacy: .public) role=\(roleStr, privacy: .public) subrole=\(subroleStr, privacy: .public) 命中白名单")
        return element
    }

    // MARK: - 第一层：Accessibility API

    private func injectViaAccessibility(_ text: String, element: AXUIElement) -> Bool {
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

    // MARK: - 第二层：Apple Events

    private func injectViaAppleScript(_ text: String) -> Bool {
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

    private func injectViaClipboard(_ text: String) {
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
        let source = CGEventSource(stateID: .hidSystemState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }
}
