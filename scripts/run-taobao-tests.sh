#!/usr/bin/env bash
#
# 淘宝接入测试：mtop 签名、请求装配、会话判定、订单解析。
#
# 签名那几条的期望值是用 Python 的 hashlib **另外算一遍**得到的，
# 不是拿 Swift 自己的输出当标准 —— 否则"实现和测试一起错"测不出来。
#
# 用法：./scripts/run-taobao-tests.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT="${TMPDIR:-/tmp}/artstock-taobao-tests"
mkdir -p "$OUT"

echo "==> 编译淘宝接入测试"
swiftc -swift-version 5 \
  -module-cache-path "$ROOT/.build-cache" \
  -o "$OUT/TaobaoTests" \
  ArtStock/Services/TaobaoAPI.swift \
  Tests/TaobaoTests/main.swift

echo "==> 运行"
"$OUT/TaobaoTests"
