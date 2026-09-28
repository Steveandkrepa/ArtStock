#!/usr/bin/env bash
#
# 收包裹解析测试：快递单号识别、承运商推断、订单文本 → 商品清单、自动匹配到库。
#
# 这一类解析错了的后果很具体：把**手机号**、**淘宝订单号（19 位）**、
# **价格**当成快递单号记下来，用户点"入库"时才发现，而且他不会怀疑解析器。
#
# 用法：./scripts/run-package-tests.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT="${TMPDIR:-/tmp}/artstock-package-tests"
mkdir -p "$OUT"

echo "==> 编译收包裹解析测试"
swiftc -swift-version 5 \
  -module-cache-path "$ROOT/.build-cache" \
  -o "$OUT/PackageTests" \
  ArtStock/Models/PresetColors.swift \
  ArtStock/Models/RefillKind.swift \
  ArtStock/Services/PaintLabelParser.swift \
  ArtStock/Services/PackageParsing.swift \
  Tests/PackageParsingTests/main.swift

echo "==> 运行"
"$OUT/PackageTests"
