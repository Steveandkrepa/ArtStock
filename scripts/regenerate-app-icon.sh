#!/usr/bin/env bash
#
# 重新生成 App 图标（1024×1024 PNG）。
#
# 图标是程序化绘制的，不是二进制素材：
#   · 换成别的设计只要改 generate-app-icon.swift 里的形状与颜色
#   · 色板刻意取自 MaterialCategory 的真实分类色，保持视觉一致
#
# 用法：
#   ./scripts/regenerate-app-icon.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"

echo "==> 编译图标生成器"
swiftc -O -module-cache-path "$ROOT/.build-cache" \
  -o "${TMPDIR:-/tmp}/artstock-icongen" \
  "$ROOT/scripts/generate-app-icon.swift"

echo "==> 渲染 1024×1024"
"${TMPDIR:-/tmp}/artstock-icongen" "$OUT"

echo "==> 完成：$OUT"
sips -g pixelWidth -g pixelHeight "$OUT" 2>/dev/null | tail -2
