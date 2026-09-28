#!/usr/bin/env bash
#
# DXArt 教材接口契约 + 落盘规则 + 下载进度测试。
#
# 这一套守的是"从 Python 搬到原生之后还能不能正常读"：
#   · JSON 解析（含厂家改字段/改类型）
#   · 页码是字符串或 null 时不崩（原脚本的 int() 会直接抛异常）
#   · 中文长书名会超文件系统 255 字节上限
#   · 进度算法（失败页不能被算成完成 —— 原脚本就是这么错的）
#
# 用法：./scripts/run-textbook-tests.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OUT="${TMPDIR:-/tmp}/artstock-textbook-tests"
mkdir -p "$OUT"

echo "==> 编译教材接口测试"
swiftc -swift-version 5 \
  -module-cache-path "$ROOT/.build-cache" \
  -o "$OUT/TextbookTests" \
  ArtStock/Services/DXArtContract.swift \
  ArtStock/Services/ReaderGeometry.swift \
  ArtStock/Services/TextbookStorage.swift \
  ArtStock/Services/TextbookDownloadPlan.swift \
  Tests/DXArtTests/main.swift

echo "==> 运行"
"$OUT/TextbookTests"
