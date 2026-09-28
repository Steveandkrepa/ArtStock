#!/usr/bin/env bash
#
# ============================================================================
#  ArtStock — Mac Worker 一键出包脚本（方案 A：Agent Host → Mac Worker）
#  ---------------------------------------------------------------------------
#  设计目标：让 hermes-mac-bridge 的 `mac.execute` 只调用**一个命令**就能拿到
#  未签名 IPA，且结果是**机器可读的 JSON**（桥直接透传给 Agent 解析）。
#
#  它是对 scripts/make-unsigned-ipa.sh 的薄封装，不重复实现构建逻辑：
#     · 环境预检（Xcode / xcodegen / iOS SDK 版本）→ 结构化报告
#     · 调 make-unsigned-ipa.sh 完成 xcodegen generate + xcodebuild + 组装
#     · 输出单行 JSON（stdout），人读日志走 stderr，两者不混淆
#
#  用法（Mac 上直接跑，或经桥 mac.execute 跑）：
#      scripts/mac-worker-build.sh [scheme] [configuration] [output.ipa]
#
#  环境变量（可选）：
#      DEVELOPER_DIR   指向完整 Xcode（xcode-select 没指对时用）
#      DERIVED_DATA    覆盖 DerivedData 目录（透传给 make-unsigned-ipa.sh）
#
#  退出码：0 = 成功（stdout 有 JSON）；非 0 = 失败（stderr 有原因，stdout 也有 JSON）
#
#  ⚠️ 桥的命令策略：bash 是解释器，走 RESTRICTED 类。要让本脚本可被
#     mac.execute 调用，需在桥配置里开 commandPolicy.allowRestricted: true。
#     详见 docs/mac-build-handoff.md。
# ============================================================================

set -euo pipefail

# ---------------------------------------------------------------- 输出约定
# 人读日志 → stderr；机器结果 → stdout（单行 JSON）。
log() { printf '%s\n' "$*" >&2; }
step() { printf '==> %s\n' "$*" >&2; }

# JSON 转义（安全处理路径/消息里的引号与反斜杠）
json_escape() {
    printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}

emit_result() {
    # $1=status  $2=message  $3=ipa_path(可空)  $4=ipa_bytes(可空)
    local status="$1" msg="$2" ipa="${3:-}" bytes="${4:-0}"
    python3 - "$status" "$msg" "$ipa" "$bytes" "$XCODE_VERSION" "$IOS_SDK_VERSION" <<'PY'
import json, sys
status, msg, ipa, bytes_, xcode, sdk = sys.argv[1:7]
print(json.dumps({
    "status": status,                 # ok | failed
    "message": msg,
    "ipa_path": ipa or None,
    "ipa_bytes": int(bytes_ or 0),
    "xcode_version": xcode or None,
    "ios_sdk_version": sdk or None,
    "scheme": SCHEME,
    "configuration": CONFIGURATION,
}, ensure_ascii=False))
PY
}

# ---------------------------------------------------------------- 参数解析
SCHEME="${1:-ArtStock}"
CONFIGURATION="${2:-Release}"
OUTPUT_ARG="${3:-}"
XCODE_VERSION=""
IOS_SDK_VERSION=""

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# ---------------------------------------------------------------- 1. 预检
step "Mac Worker 构建 — 预检"
log "仓库根目录 : $PROJECT_ROOT"
log "scheme     : $SCHEME"
log "配置       : $CONFIGURATION"

# 1a. 完整 Xcode（不是只有 Command Line Tools）
DEVELOPER_PATH="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || echo '')}"
if ! printf '%s' "$DEVELOPER_PATH" | grep -q 'Xcode.app/Contents/Developer'; then
    emit_result failed "xcode-select 未指向完整 Xcode：${DEVELOPER_PATH:-<取不到>}（需要 Xcode.app/Contents/Developer）"
    exit 1
fi
XCODE_VERSION="$(xcodebuild -version 2>/dev/null | head -1)"
log "Xcode       : $XCODE_VERSION"

# 1b. iOS SDK 版本（只报告，不硬拦 —— 老 SDK 会退化材质外观，仍能出包）
IOS_SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || echo '')"
log "iOS SDK     : ${IOS_SDK_VERSION:-<取不到>}"

# 1c. xcodegen（make-unsigned-ipa.sh 内部还会再查一次，这里提前给清晰报错）
if ! command -v xcodegen >/dev/null 2>&1; then
    emit_result failed "找不到 xcodegen（brew install xcodegen）"
    exit 1
fi
log "xcodegen    : $(xcodegen --version 2>&1)"

# 1d. 工程描述文件存在
[ -f "$PROJECT_ROOT/project.yml" ] || {
    emit_result failed "找不到 $PROJECT_ROOT/project.yml"
    exit 1
}

# ---------------------------------------------------------------- 2. 出包
step "调用 make-unsigned-ipa.sh（xcodegen generate → xcodebuild → 组装）"
BUILD_ARGS=( "$SCHEME" "$CONFIGURATION" )
[ -n "$OUTPUT_ARG" ] && BUILD_ARGS+=( "$OUTPUT_ARG" )

if ! "$SCRIPT_DIR/make-unsigned-ipa.sh" "${BUILD_ARGS[@]}"; then
    emit_result failed "make-unsigned-ipa.sh 失败（详见上方构建日志）"
    exit 1
fi

# ---------------------------------------------------------------- 3. 定位产物
step "定位 IPA 产物"
# 脚本默认输出 build/ArtAssist-<Config>-<时间戳>.ipa；显式传了路径就用那个。
if [ -n "$OUTPUT_ARG" ]; then
    case "$OUTPUT_ARG" in
        /*) IPA_PATH="$OUTPUT_ARG" ;;
        *)  IPA_PATH="$(pwd)/$OUTPUT_ARG" ;;
    esac
else
    IPA_PATH="$(ls -t "$PROJECT_ROOT"/build/ArtAssist-${CONFIGURATION}-*.ipa 2>/dev/null | head -1 || true)"
fi

if [ -z "$IPA_PATH" ] || [ ! -f "$IPA_PATH" ]; then
    emit_result failed "构建成功但找不到 IPA 产物（已扫描 $PROJECT_ROOT/build/ 下 ArtAssist-${CONFIGURATION}-*.ipa）"
    exit 1
fi

IPA_BYTES="$(stat -f%z "$IPA_PATH" 2>/dev/null || stat -c%s "$IPA_PATH" 2>/dev/null || echo 0)"
log "IPA         : $IPA_PATH ($(du -h "$IPA_PATH" | awk '{print $1}'))"

# ---------------------------------------------------------------- 4. 汇报
emit_result ok "构建成功" "$IPA_PATH" "$IPA_BYTES"
log "完成。IPA 未签名，可直接交给 SideStore 重签安装。"
