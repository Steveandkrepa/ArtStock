#!/usr/bin/env bash
#
# 扫码解析器（PaintScanParser）回归测试。
#
# 与干燥模型、补充装算术同样的理由：它只依赖 Foundation，可以脱离 iOS SDK 直接跑。
# 守住的是嵌套 JSON 摊平、中文键宽松匹配、GS1 括号写法切分、
# 零售条码不被误判成 GS1、中文色名映射这些容易写错又难肉眼发现的边界。
#
# 一并编译 PaintLabelParser —— `nameBasedCode` 复用了它的 slug，
# 而且"条码被多个颜色共用"这条判定必须和认字那条路一起测。
#
# 用法：
#   ./scripts/run-scan-tests.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT="${TMPDIR:-/tmp}/artstock-scan-tests"
mkdir -p "$OUT"

echo "==> 编译解析器测试"
swiftc -swift-version 5 \
  -module-cache-path "$ROOT/.build-cache" \
  -o "$OUT/ScanTests" \
  ArtStock/Models/PresetColors.swift \
  ArtStock/Services/PaintLabelParser.swift \
  ArtStock/Services/PaintScanParser.swift \
  Tests/ScanParserTests/main.swift

echo "==> 运行"
"$OUT/ScanTests"
