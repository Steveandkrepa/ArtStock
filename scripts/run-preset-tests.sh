#!/usr/bin/env bash
#
# 42 色预设色卡的数据完整性测试。
#
# 预设是数据，低级错误（色值少一位、序号重了、顺序错位）不会让编译失败，
# 但会让用户装出来一盒错的颜色 —— 所以单独测。
#
# 用法：./scripts/run-preset-tests.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT="${TMPDIR:-/tmp}/artstock-preset-tests"
mkdir -p "$OUT"

echo "==> 编译预设测试"
swiftc -swift-version 5 \
  -module-cache-path "$ROOT/.build-cache" \
  -o "$OUT/PresetTests" \
  ArtStock/Models/PresetColors.swift \
  Tests/PresetColorsTests/main.swift

echo "==> 运行"
"$OUT/PresetTests"
