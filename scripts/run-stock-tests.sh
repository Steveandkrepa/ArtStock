#!/usr/bin/env bash
#
# 「库存与采购」统一结论测试（StockPlan）。
#
# 其他耗材并进库存体系之后，"该买什么"是一句话给出来的。
# 这句话算错了，用户会重复购买或者漏买，而且他自己不会知道。
#
# 用法：./scripts/run-stock-tests.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT="${TMPDIR:-/tmp}/artstock-stock-tests"
mkdir -p "$OUT"

echo "==> 编译统一结论测试"
swiftc -swift-version 5 \
  -module-cache-path "$ROOT/.build-cache" \
  -o "$OUT/StockTests" \
  ArtStock/Models/RefillKind.swift \
  ArtStock/Services/StockPlan.swift \
  Tests/StockPlanTests/main.swift

echo "==> 运行"
"$OUT/StockTests"
