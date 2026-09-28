#!/usr/bin/env bash
#
# PP-OCR 字符表 / CTC 解码 / 输入归一化测试。
#
# 「换成更高级的轻量 OCR 模型」这条路里，最容易错、最难发现的就是这三件事：
#   · 字符表索引约定（blank 在 0、字典从 1 起、空格在末尾）
#   · CTC 解码（被 blank 隔开的重复字是**两个字**，不是去重）
#   · 输入归一化（/255 再 (v-0.5)/0.5 到 −1…1，CHW 排列）
# 全是纯数学 + 查表，不需要模型就能测 —— 所以先测透，
# 等运行时到位只剩"把张量喂进来"这层胶水。
#
# 用法：./scripts/run-paddleocr-tests.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT="${TMPDIR:-/tmp}/artstock-paddleocr-tests"
mkdir -p "$OUT"

echo "==> 编译 PP-OCR 解码测试"
swiftc -swift-version 5 \
  -module-cache-path "$ROOT/.build-cache" \
  -o "$OUT/PaddleOCRTests" \
  ArtStock/Services/PaddleOCRTokens.swift \
  Tests/PaddleOCRTests/main.swift

echo "==> 运行"
"$OUT/PaddleOCRTests"
