#!/usr/bin/env bash
#
# OCR 文字 → 颜色 的推断逻辑测试。
#
# 相机与 Vision 的准确率没法离线测，但"读到「群青」该落到哪一格"这件事
# 必须测得动 —— 改一个正则就可能把 42 个颜色全认错，而且编译不会报错。
#
# 用法：./scripts/run-label-tests.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT="${TMPDIR:-/tmp}/artstock-label-tests"
mkdir -p "$OUT"

echo "==> 编译认字解析测试"
swiftc -swift-version 5 \
  -module-cache-path "$ROOT/.build-cache" \
  -o "$OUT/LabelTests" \
  ArtStock/Models/PresetColors.swift \
  ArtStock/Services/PaintLabelParser.swift \
  Tests/LabelParserTests/main.swift

echo "==> 运行"
"$OUT/LabelTests"
