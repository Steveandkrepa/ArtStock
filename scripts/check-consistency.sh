#!/usr/bin/env bash
#
# 跨文件接口一致性检查。
#
# 为什么需要它：本工程在开发机上没有 iOS SDK，无法对 SwiftUI / UIKit 层做类型检查，
# 而下面这两类错误 **语法检查抓不到**（swiftc -parse 会通过），只有类型检查才能发现：
#
#   1. 自定义 View 的 memberwise init 标签写错或顺序不对
#      例：LabelPreviewView(selectedMaterials:) 写成了 LabelPreviewView(materials:)
#   2. 自有类型的静态成员 / 枚举 case 名字打错
#      例：Fmt.expiryDescription 写成 Fmt.expireDescription
#
# 本脚本用机械方式把这两类都核对一遍，作为"没有类型检查"的补偿。
#
# 用法：
#   ./scripts/check-consistency.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "==> 跨文件接口一致性检查"
python3 scripts/check-consistency.py
