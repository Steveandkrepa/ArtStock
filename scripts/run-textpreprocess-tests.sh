#!/usr/bin/env bash
#
# OCR 图像预处理测试（TextImagePreprocessor）。
#
# 这一套守的是**针对工业喷码的四步处理**：
#   放大 → 对比度均衡 → 局部自适应二值化 → 形态学闭运算
#
# 全是合成图：自己画点阵字、画明暗渐变的底，验证该连的连上了、
# 该分开的分开了。不测的话，"看起来在跑"和"其实没效果"外观上没区别 ——
# OCR 认不出来时你无法判断是图没处理好还是模型不行。
#
# 用法：./scripts/run-textpreprocess-tests.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT="${TMPDIR:-/tmp}/artstock-textpre-tests"
mkdir -p "$OUT"

echo "==> 编译预处理测试"
swiftc -swift-version 5 \
  -module-cache-path "$ROOT/.build-cache" \
  -o "$OUT/TextPreTests" \
  ArtStock/Services/TextImagePreprocessor.swift \
  Tests/TextPreprocessTests/main.swift

echo "==> 运行"
"$OUT/TextPreTests"
