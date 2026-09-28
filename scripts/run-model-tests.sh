#!/usr/bin/env bash
#
# 干燥模型回归测试。
#
# 与 run-parser-tests.sh 同样的理由：DryingModel.swift 只依赖 Foundation，
# 刻意不引入 SwiftUI / SwiftData，因此可以在 macOS 上直接编译运行。
# 这是"颜料湿润计时器"这个功能里唯一能被真正验证的部分 ——
# 物理式的正确性、标定的回环一致性、边界稳健性都靠它守住。
#
# 用法：
#   ./scripts/run-model-tests.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT="${TMPDIR:-/tmp}/artstock-model-tests"
mkdir -p "$OUT"

echo "==> 编译模型测试"
swiftc -swift-version 5 \
  -module-cache-path "$ROOT/.build-cache" \
  -o "$OUT/ModelTests" \
  ArtStock/Services/DryingModel.swift \
  Tests/ModelTests/main.swift

echo "==> 运行"
"$OUT/ModelTests"
