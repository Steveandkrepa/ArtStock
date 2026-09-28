#!/usr/bin/env bash
#
# 取色算法测试（ColorGridSampler）。
#
# 这一套守的是两个"肉眼很难发现"的错：
#   · BGRA 通道顺序写反 → 整套颜色红蓝颠倒，看着像偏色
#   · 格子划分偏半格 → 采到隔壁颜料或塑料隔断，整体发灰
#
# 相机没法离线测，但这两件事可以用合成图像钉死。
#
# 用法：./scripts/run-sampler-tests.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT="${TMPDIR:-/tmp}/artstock-sampler-tests"
mkdir -p "$OUT"

echo "==> 编译取色算法测试"
swiftc -swift-version 5 \
  -module-cache-path "$ROOT/.build-cache" \
  -o "$OUT/SamplerTests" \
  ArtStock/Services/ColorGridSampler.swift \
  Tests/ColorSamplerTests/main.swift

echo "==> 运行"
"$OUT/SamplerTests"
