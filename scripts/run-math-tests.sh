#!/usr/bin/env bash
#
# 补充装算术（"不缺也不过多"的核心）回归测试。
#
# RefillMath.swift 只依赖 Foundation，所以能脱离 iOS SDK 直接跑。
# 这几个算术一旦错了，用户要么漏买（颜料断档）要么多买（占地方费钱），
# 而它们又完全独立于 SwiftData 与界面 —— 没有理由不测。
#
# 用法：
#   ./scripts/run-math-tests.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT="${TMPDIR:-/tmp}/artstock-math-tests"
mkdir -p "$OUT"

echo "==> 编译算术测试"
swiftc -swift-version 5 \
  -module-cache-path "$ROOT/.build-cache" \
  -o "$OUT/MathTests" \
  ArtStock/Services/RefillMath.swift \
  Tests/RefillMathTests/main.swift

echo "==> 运行"
"$OUT/MathTests"
