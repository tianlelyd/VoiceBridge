#!/bin/bash
# 局域网直连端到端测试：对 /Applications/VoiceBridge.app（Debug，先跑 scripts/run-dev.sh）跑完整链路。
# 产物在 build/e2e/<时间戳>/：report.md（逐条结果和回执）、client.log、voicebridge.log（App 的 os_log）。
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
APP="/Applications/VoiceBridge.app"
OUT="$PROJECT_DIR/build/e2e/$(date +%Y%m%d-%H%M%S)"
BIN="$PROJECT_DIR/build/e2e/bin"
mkdir -p "$OUT" "$BIN"

echo "== 编译测试客户端和测试窗口"
swiftc -O -parse-as-library -o "$BIN/e2e-client" \
    "$PROJECT_DIR/VoiceBridge/Shared/LocalBridgeWire.swift" \
    "$PROJECT_DIR/VoiceBridge/Shared/LocalBridgePairing.swift" \
    "$PROJECT_DIR/VoiceBridgeTests/LocalBridgeTestClient.swift" \
    "$PROJECT_DIR/scripts/e2e/main.swift"
swiftc -O -o "$BIN/e2e-window" "$PROJECT_DIR/scripts/e2e/TestWindow.swift"

echo "== 带 --e2e-pair 重启 VoiceBridge"
START="$(date '+%Y-%m-%d %H:%M:%S')"
pkill -x VoiceBridge 2>/dev/null || true
sleep 1
rm -f "$OUT/pairing.txt"
open -n "$APP" --args --e2e-pair "$OUT/pairing.txt"
for _ in $(seq 1 50); do [ -s "$OUT/pairing.txt" ] && break; sleep 0.2; done
[ -s "$OUT/pairing.txt" ] || { echo "VoiceBridge 没有写出配对载荷（需要 Debug 构建）"; exit 1; }

echo "== 打开测试输入窗口"
WINDOW_PIPE="$OUT/window.out"
"$BIN/e2e-window" "$OUT/field.txt" > "$WINDOW_PIPE" 2>&1 &
WINDOW_PID=$!
trap 'kill $WINDOW_PID 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do grep -q ready "$WINDOW_PIPE" 2>/dev/null && break; sleep 0.1; done
sleep 0.5

echo "== 跑用例"
set +e
"$BIN/e2e-client" "$OUT/pairing.txt" "$OUT/field.txt" "$WINDOW_PID" "$OUT/report.md" | tee "$OUT/client.log"
STATUS=${PIPESTATUS[0]}
set -e

log show --style compact --start "$START" \
    --predicate 'subsystem == "app.doodto.VoiceBridge"' > "$OUT/voicebridge.log" 2>/dev/null || true

# 配对载荷含密钥，不留在产物里
rm -f "$OUT/pairing.txt"

echo "== 吊销 E2E 设备并正常重启 VoiceBridge"
pkill -x VoiceBridge 2>/dev/null || true
sleep 1
open -n "$APP" --args --e2e-unpair
DEVICES="$HOME/Library/Application Support/VoiceBridge/paired-devices.json"
for _ in $(seq 1 25); do grep -q '"name":"E2E"' "$DEVICES" 2>/dev/null || break; sleep 0.2; done
if grep -q '"name":"E2E"' "$DEVICES" 2>/dev/null; then
    echo "- ❌ 收尾：E2E 设备没有被吊销" >> "$OUT/report.md"; STATUS=1
else
    echo "- ✅ 收尾：E2E 设备已吊销" >> "$OUT/report.md"
fi
echo "== 产物: $OUT"
exit "$STATUS"
