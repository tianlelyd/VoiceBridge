# CLAUDE.md

## 项目

VoiceBridge — macOS 菜单栏 App，通过飞书机器人 WebSocket 长链接接收手机端语音输入的文字，自动插入到 Mac 当前焦点位置。

## 技术栈

- Swift, SwiftUI, macOS 14+
- 纯原生实现，不依赖 Node.js 或任何 JS 运行时
- MenuBarExtra 做菜单栏常驻
- URLSessionWebSocketTask 做飞书 WebSocket 连接
- Accessibility API + Apple Events + CGEvent 做文本注入

## 关键技术点

### 飞书连接
- 用 App ID + App Secret 换 tenant_access_token
- 通过 token 建立 WebSocket 长链接
- 监听 im.message.receive_v1 事件
- 断线指数退避重连

### 文本注入（三层降级）
1. AXUIElement kAXSelectedTextAttribute 直接写入（不污染剪贴板）
2. NSAppleScript System Events keystroke（降级）
3. NSPasteboard + CGEvent Cmd+V（兜底，需保存恢复剪贴板）

### 权限
- 需要辅助功能权限（Accessibility）
- 需要 Apple Events 权限
- 禁用 App Sandbox

## 代码规范
- 文件组织：Views/, Services/, Models/, Utilities/
- 用 async/await，不用 completion handler
- 敏感信息（App Secret）存 Keychain
- 日志用 os.Logger

## 开发工作流

代码修改完成后，按以下顺序自动执行，无需用户手动触发：

### 1. 代码审查

运行 `/simplify` 进行代码审查优化，修复发现的问题。

### 2. 编译并启动

Debug 和 Release 均固定使用 `Developer ID Application: YanDong Li (97ZLXJHDD3)`，保持相同 Bundle ID 和签名要求。Debug 独立启用 `get-task-allow`；Release 禁用。不要临时改回 Apple Development 或 ad-hoc 签名。

```bash
# 构建并验证 Debug，备份已安装版本，安装到固定路径后重启
bash scripts/run-dev.sh
```

始终从 `/Applications/VoiceBridge.app` 启动日常开发测试版本，避免与 DerivedData 中的同名副本混淆。首次从旧开发签名切换时，可能需要重新添加辅助功能授权。机器人配置仍复用原有存储。

## 项目规格文档
详见 VoiceBridge-Spec.md
