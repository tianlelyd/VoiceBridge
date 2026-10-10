# VoiceBridge

Turn your phone into a wireless voice keyboard for Mac.

A macOS menu bar app that receives voice-to-text messages from your phone via a Feishu (Lark) bot WebSocket connection, and automatically inserts them at the current cursor position on your Mac.

[中文文档](#中文文档)

## How It Works

1. VoiceBridge runs in the background, showing connection status in the menu bar
2. Place your cursor where you want to type on any Mac app
3. Pick up your phone, open the Feishu bot chat, and send a voice message
4. Feishu converts your speech to text
5. Text appears instantly at the cursor position on your Mac

## Getting Started

### Install

Download the latest DMG from [Releases](https://github.com/tianlelyd/VoiceBridge/releases).

### Setup

On first launch, a setup wizard guides you through three steps:

1. **Grant Accessibility permission** — the app needs this to detect the focused input field and insert text
2. **Create your Feishu bot** — scan the QR code with Feishu on your phone, name your bot, done. Credentials are obtained automatically — no manual App ID / Secret entry needed
3. **Ready to go** — the bot connects and VoiceBridge starts listening

That's it. Open any app on your Mac, place the cursor, and send a voice message to your bot in Feishu.

### Menu Bar

The menu bar icon shows the connection status:

- Green dot — Connected
- Orange dot — Connecting / Reconnecting
- White dot — Disconnected

### Settings

- **Multiple bots** — add more bots via QR code, toggle between them (one active at a time)
- **Launch at login** — optional auto-start
- **Permissions** — check Accessibility authorization status

## Features

- **Pure Swift implementation** — no Node.js or any JS runtime dependency
- **One-step bot creation** — scan QR code to create and configure the Feishu bot automatically
- **Feishu WebSocket long connection** — custom Protobuf codec, no Feishu SDK needed
- **Three-layer text injection with fallback**:
  - Accessibility API (clipboard-free)
  - Apple Events keystroke (fallback)
  - Clipboard + Cmd+V (last resort, auto-restores original clipboard)
- **Electron app compatible** (Feishu desktop, Claude desktop, etc.) — auto-detects web views to skip unreliable AX API
- **Message deduplication + expiry checks** — prevents WebSocket redelivery and reconnect replay
- **Auto-reconnect** with exponential backoff and randomized jitter
- **No-focus-target guard** — silently discards text when no input field is focused
- **Secure credential storage** — App Secret stored in macOS Keychain

## Requirements

- macOS 13+
- Accessibility permission
- Apple Events permission

## Build from Source

```bash
git clone https://github.com/tianlelyd/VoiceBridge.git
cd VoiceBridge
open VoiceBridge.xcodeproj
```

To build a signed and notarized DMG (requires a Developer ID certificate):

```bash
./scripts/build-dmg.sh
```

The script auto-detects your Developer ID certificate from the local keychain. You can also specify it explicitly:

```bash
CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/build-dmg.sh 1.0.0
```

## Project Structure

```
VoiceBridge/
├── VoiceBridgeApp.swift          # App entry, MenuBarExtra
├── Views/
│   ├── MenuBarView.swift         # Menu bar dropdown
│   ├── SettingsView.swift        # Settings panel (multi-bot, permissions, general)
│   └── OnboardingView.swift      # First-launch setup wizard
├── Services/
│   ├── FeishuClient.swift        # Feishu WebSocket, message parsing, dedup
│   ├── TextInjector.swift        # Three-layer text injection
│   └── PermissionManager.swift   # Accessibility permission detection
├── Models/
│   ├── BotConfiguration.swift    # Bot config model (multi-bot support)
│   └── FeishuMessage.swift       # Feishu event data models
├── Utilities/
│   ├── ProtobufCodec.swift       # Minimal Protobuf codec
│   ├── KeychainHelper.swift      # Keychain secure storage
│   └── QRCodeGenerator.swift     # QR code generation for bot registration
└── Assets.xcassets
```

## License

MIT

---

# 中文文档

把手机变成 Mac 的无线语音键盘。

macOS 菜单栏常驻 App，通过飞书机器人 WebSocket 长连接接收手机端语音输入的文字，自动插入到 Mac 当前光标所在的输入位置。

## 工作流程

1. Mac 端 VoiceBridge 后台运行，菜单栏显示连接状态
2. 在 Mac 上任意应用中将光标放到要输入的位置
3. 拿起手机，在飞书中打开机器人对话，发送语音消息
4. 飞书将语音识别为文字
5. Mac 端实时收到文字，自动插入到光标位置

## 快速开始

### 安装

从 [Releases](https://github.com/tianlelyd/VoiceBridge/releases) 下载最新 DMG。

### 本地开发签名

Debug 和 Release 均使用 `Developer ID Application: YanDong Li (97ZLXJHDD3)`，本机钥匙串需安装对应证书和私钥。运行 `bash scripts/run-dev.sh` 可构建 Debug、备份现有应用，并安装到 `/Applications/VoiceBridge.app` 后打开；机器人配置继续复用。Debug 允许调试器附加，Release 不允许。

首次从 Apple Development 签名切换时，可能需要在系统设置中移除旧的 VoiceBridge 辅助功能授权条目，再添加 `/Applications/VoiceBridge.app`。后续保持相同签名身份，不要在日常测试中混用其他签名。

签名验收：在同一个 DerivedData 目录完成 Debug 和 Release 构建后，运行 `python3 scripts/verify-signing.py <DerivedData>/Build/Products build/signing-verification.json`，检查证书、Bundle ID、签名要求及调试权限，并保存 JSON 报告。

### 设置向导

首次启动会进入设置向导，三步完成：

1. **授权辅助功能权限** — 应用需要此权限来检测焦点输入框并插入文字
2. **创建飞书机器人** — 用飞书扫描屏幕上的二维码，给机器人取个名字即可。凭据自动获取，无需手动填写 App ID / App Secret
3. **一切就绪** — 机器人自动连接，VoiceBridge 开始监听

设置完成。在 Mac 上打开任意应用，将光标放到输入位置，在飞书中给机器人发送语音消息即可。

### 菜单栏

菜单栏图标显示连接状态：

- 绿点 — 已连接
- 橙点 — 连接中 / 重连中
- 白点 — 未连接

### 设置面板

- **多机器人** — 通过扫码添加多个机器人，可切换使用（同时只有一个生效）
- **开机自动启动** — 可选
- **权限状态** — 查看辅助功能授权情况

## 技术特性

- **纯 Swift 原生实现**，不依赖 Node.js 或任何 JS 运行时
- **一步创建机器人** — 扫码自动创建并配置飞书机器人
- **飞书 WebSocket 长连接**，自研 Protobuf 编解码，无需飞书 SDK
- **三层文本注入降级策略**：
  - Accessibility API（不污染剪贴板）
  - Apple Events keystroke（降级）
  - 剪贴板 + Cmd+V（兜底，自动恢复原剪贴板内容）
- **Electron 应用兼容**（飞书、Claude 桌面版等），自动检测 Web 视图跳过不可靠的 AX API
- **消息去重 + 过期检查**，防止 WebSocket 重发和重连重放
- **断线自动重连**，指数退避 + 随机抖动
- **无焦点输入框时自动丢弃**，不会缓存按键导致意外输入
- **凭据安全存储** — App Secret 存储在 macOS 钥匙串中

## 系统要求

- macOS 13+
- 辅助功能权限（Accessibility）
- Apple Events 权限

## 从源码构建

```bash
git clone https://github.com/tianlelyd/VoiceBridge.git
cd VoiceBridge
open VoiceBridge.xcodeproj
```

构建签名并公证的 DMG（需要 Developer ID 证书）：

```bash
./scripts/build-dmg.sh
```

脚本会自动从本地钥匙串检测 Developer ID 证书。也可以显式指定：

```bash
CODE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/build-dmg.sh 1.0.0
```

## 项目结构

```
VoiceBridge/
├── VoiceBridgeApp.swift          # App 入口，MenuBarExtra
├── Views/
│   ├── MenuBarView.swift         # 菜单栏下拉内容
│   ├── SettingsView.swift        # 设置面板（多机器人、权限、通用）
│   └── OnboardingView.swift      # 首次启动设置向导
├── Services/
│   ├── FeishuClient.swift        # 飞书 WebSocket 长连接、消息解析、去重
│   ├── TextInjector.swift        # 三层文本注入
│   └── PermissionManager.swift   # 辅助功能权限检测
├── Models/
│   ├── BotConfiguration.swift    # 机器人配置模型（多机器人支持）
│   └── FeishuMessage.swift       # 飞书事件数据模型
├── Utilities/
│   ├── ProtobufCodec.swift       # 最小化 Protobuf 编解码器
│   ├── KeychainHelper.swift      # Keychain 安全存储
│   └── QRCodeGenerator.swift     # 二维码生成（机器人注册用）
└── Assets.xcassets
```

## 许可证

MIT
