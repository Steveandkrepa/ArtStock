#!/usr/bin/env bash
#
# OCR 实验室：拿真实包装照片做对照实验。
#
# 同一张图喂给多条管线（原图 / 增强 / 喷码 / 数码变焦 / 编号模式），
# 把结果并排列出来 —— 于是"预处理到底有没有用、哪一档最好"是看得出来的，
# 而不是靠感觉。
#
# Vision 在 macOS 上也有，预处理是纯 CoreGraphics，所以整条链能原样在 Mac 上跑。
#
# 用法：
#   ./scripts/run-ocr-lab.sh --selftest
#   ./scripts/run-ocr-lab.sh 照片.jpg
#   ./scripts/run-ocr-lab.sh 照片.jpg 群青

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT="${TMPDIR:-/tmp}/artstock-ocr-lab"
mkdir -p "$OUT"

swiftc -O -swift-version 5 \
  -module-cache-path "$ROOT/.build-cache" \
  -o "$OUT/ocrlab" \
  scripts/paint-ocr-lab/main.swift \
  ArtStock/Services/TextImagePreprocessor.swift \
  ArtStock/Models/PresetColors.swift

"$OUT/ocrlab" "$@"
