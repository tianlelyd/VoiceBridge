# VoiceBridge 局域网直连协议 v1（AIInput ↔ VoiceBridge）

AIInput（iPhone/iPad）在同一局域网或同一 Tailscale 网络里直连 Mac 上的 VoiceBridge，发文字、按键，拿注入回执。飞书通道不受影响。

实现：`VoiceBridge/Shared/LocalBridgeWire.swift`（线格式）、`LocalBridgeSession.swift`（状态机）、`LocalBridgeServer.swift`（网络）、`LocalBridgePairing.swift`（二维码载荷、地址）。参考客户端：`VoiceBridgeTests/LocalBridgeTestClient.swift`。

## 1. 配对二维码

在 VoiceBridge 设置 →「手机直连（AIInput）」→「添加设备」生成。每次添加生成一个新的 `deviceId` 和 32 字节随机密钥，密钥按 `deviceId` 存入 Mac 钥匙串（`local-bridge-device-<deviceId>`），可在设备列表里吊销。如果关掉「添加设备」窗口时这台设备还没握手成功过，30 秒内仍没连上就自动删除（设备条目和钥匙串密钥一起删）；App 启动时也会清掉从没握手成功过的设备。

二维码内容：

```
aiinput://pair?p=<base64url(JSON)>
```

base64url 无填充（`-`、`_`，不带 `=`）。JSON：

```json
{
  "v": 1,
  "macId": "8F0C…",             // Mac 的稳定 UUID
  "macName": "李的 MacBook Pro",
  "deviceId": "3A1B…",          // 这台手机的 id，握手时带上
  "key": "<base64，32 字节>",    // 配对密钥，手机存 Keychain
  "port": 47800,
  "bonjour": "_aiinput._tcp",
  "hosts": [
    {"kind": "lan",       "host": "Lis-MacBook-Pro.local"},
    {"kind": "lan",       "host": "192.168.1.23"},
    {"kind": "tailscale", "host": "100.101.12.34"},
    {"kind": "tailscale", "host": "lis-macbook-pro.tail1234.ts.net"}
  ]
}
```

- `v` 不是 1 时手机应拒绝并提示升级。
- `hosts` 按建议尝试顺序排列：局域网 `.local` 主机名、硬件网卡（系统设置里的硬件端口：Wi-Fi、以太网、雷雳网桥）上的私网 IPv4、任意网卡上 `100.64.0.0/10` 的 Tailscale 地址、Tailscale MagicDNS 名（来自 `tailscale status --json`，读不到就省略）。虚拟机/容器网卡（OrbStack、Parallels、互联网共享的 `bridge100+`，VMware 的 `vmnet*`，Parallels 的 `vnic*` 等）、其他 VPN（utun 上的私网地址）、回环、链路本地地址不会出现。列表可能为空。
- 连接策略：先用 Bonjour 找 `_aiinput._tcp` 且 TXT `mac` 等于 `macId` 的服务；约 1 秒没找到就按 `hosts` 顺序直连 `ws://<host>:<port>/`。authOK 里会带最新的 `hosts`，手机应覆盖本地缓存。
- Bonjour TXT：`mac=<macId>`，`v=1`；服务名为 `macName`。

## 2. 连接

WebSocket（文本帧）跑在 TCP 上，不加 TLS，路径 `/`。机密性和完整性靠下面的会话加密。

## 3. 握手（明文 JSON）

```
Mac → 手机  {"type":"hello","v":1,"macId":"…","macName":"…","challenge":"<base64，32 字节>"}
手机 → Mac  {"type":"auth","v":1,"deviceId":"…","deviceName":"小李的 iPhone","mac":"<base64 HMAC>","sentAt":1735000000.12}
Mac → 手机  {"type":"authOK","v":1,"sessionId":"…","macId":"…","serverTime":1735000000.15,"hosts":[…]}
         或 {"type":"authFail","reason":"badMac" | "unknownDevice" | "version"}，随后断开
```

- `mac = HMAC-SHA256(key: 配对密钥, data: challenge 原始字节 ‖ deviceId 的 UTF-8)`，base64。
- `v` 缺省按 1；`deviceName` 可选，Mac 用它替换设备列表里的占位名。
- 连接后 10 秒内没完成握手会被断开；握手前收到 `auth` 以外的帧直接断开。

## 4. 会话加密

握手成功后双方派生会话密钥：

```
sessionKey = HKDF-SHA256(ikm: 配对密钥, salt: challenge, info: "aiinput-mlink-v1", 32 字节)
```

之后每一帧都是：

```json
{"type":"box","c":"<base64(ChaChaPoly combined = nonce(12) ‖ 密文 ‖ tag(16))>"}
```

明文是下面的 JSON。连续 3 帧解不开（或不是 box）Mac 会断开；解开一帧计数清零。

## 5. 消息

### 手机 → Mac

```json
{"type":"insert","id":"<唯一 id>","text":"你好","createdAt":1735000001.5,"ttlMs":10000,"then":"enter"}
{"type":"key","id":"<唯一 id>","kind":"enter" | "shiftEnter" | "clear","createdAt":1735000001.5,"ttlMs":10000}
{"type":"ping","id":"p1"}
```

- `createdAt` 是 **Unix 秒（浮点）**，按 **Mac 时钟** 计：手机用 authOK 的 `serverTime` 算出时钟差后换算。`ttlMs` 是毫秒，缺省 10000。Mac 收到时 `now > createdAt + ttlMs/1000` 就不注入，回 `expired`。
- `then` 可选：`enter` / `shiftEnter`，文字注入成功后再按键。
- 没有 `id` 的 insert/key 不处理也不回执。

### Mac → 手机

```json
{"type":"ack","id":"…","status":"injected","method":"ax","injectMs":3,"serverTime":1735000001.6}
{"type":"ack","id":"…","status":"noFocus","serverTime":…}
{"type":"ack","id":"…","status":"expired","serverTime":…}
{"type":"ack","id":"…","status":"error","message":"VoiceBridge 未获得辅助功能权限","serverTime":…}
{"type":"ack","id":"…","status":"duplicate","first":{"status":"injected","method":"ax"},"serverTime":…}
{"type":"pong","id":"p1"}
```

- `method`：`ax`（辅助功能直接写入）、`appleEvents`、`clipboard`（剪贴板 + ⌘V）、`keyEvent`（按键消息）。
- `noFocus`：焦点不在可输入的位置，文字被丢弃。
- `duplicate`：同一 `id` 在 10 分钟内（跨连接、跨设备）已处理过，不再注入，`first` 是第一次的结果。手机断线重发时用同一个 `id` 即可。

## 6. 与原型（ai-input 仓库 MacLinkWire）的差异

- 支持多台设备：密钥按 `deviceId` 查，未配对的 `deviceId` 回 `unknownDevice`。
- authOK 增加 `v`、`macId`、`hosts`；hello 增加 `v`。
- duplicate 回执改为 `status:"duplicate"` + `first`（原型是 `"duplicate:injected"` 字符串）。
- 新增 `key` 消息、`then`、`error` 状态和 `message` 字段。
