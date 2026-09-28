#!/usr/bin/env bash
#
# ArtStock — 本机可跑的**全部**验证，一次执行完。
#
# 为什么需要它：开发机上没有 iOS SDK，所以 `xcodebuild` 编译这一环无法在本地覆盖。
# 本脚本把**不需要 iOS SDK 就能做**的验证全部跑一遍，作为提交前的门槛：
#
#   1. 语法检查        —— 全部 .swift 走 swiftc -parse
#   2. 接口一致性      —— View 的 memberwise init 标签 + 自有类型静态成员引用
#   3. 纯逻辑回归测试  —— 扫码解析 / 补充装算术 / 干燥模型 / 预设色卡，共 208 个用例
#   4. 配置文件合法性  —— YAML / Info.plist / asset catalog / shell 脚本
#   5. 图标合规性      —— 尺寸与非 alpha 通道
#   6. 真实编译        —— 有 Xcode 时跑一次完整 xcodebuild（最关键的一项）
#
# 用法：
#   ./scripts/verify-all.sh
#
# 退出码：0 = 全部通过；非 0 = 有检查项失败（失败项会标出来）。

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BOLD=$'\033[1m'; GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; RESET=$'\033[0m'
FAILED=()
step() { printf '\n%s── %s%s\n' "$BOLD" "$*" "$RESET"; }
pass() { printf '%s   ✓ %s%s\n' "$GREEN" "$*" "$RESET"; }
fail() { printf '%s   ✗ %s%s\n' "$RED" "$*" "$RESET"; FAILED+=("$*"); }

printf '%s╔══════════════════════════════════════════════════════════╗%s\n' "$BOLD" "$RESET"
printf '%s║  ArtStock — 本机验证套件（不需要 iOS SDK）              ║%s\n' "$BOLD" "$RESET"
printf '%s╚══════════════════════════════════════════════════════════╝%s\n' "$BOLD" "$RESET"
printf '%s  第 6 步需要完整 Xcode；没有时会自动跳过而不是报错。%s\n' "$DIM" "$RESET"

# ───────────────────────────────────────────── 1. 语法检查
step "1/6  Swift 语法检查（swiftc -parse）"
SWIFT_FILES=$(find ArtStock -name '*.swift' | sort)
COUNT=$(printf '%s\n' "$SWIFT_FILES" | wc -l | tr -d ' ')
if swiftc -parse $SWIFT_FILES 2>/tmp/artstock-parse.log; then
    pass "$COUNT 个文件语法全部通过"
else
    fail "语法检查失败"; sed 's/^/      /' /tmp/artstock-parse.log | head -30
fi

# ───────────────────────────────────────────── 2. 接口一致性
step "2/6  跨文件接口一致性（补偿缺失的类型检查）"
if python3 scripts/check-consistency.py; then
    pass "init 标签与静态成员引用全部匹配"
else
    fail "接口一致性检查未通过"
fi

# ───────────────────────────────────────────── 2.5 数据模型迁移安全
#
# 这一关是为一次真实的数据事故加的：给 @Model 加了"非可选且无默认值"的新字段，
# 轻量迁移失败 → store 打不开 → 静默降级到内存库 →
# 用户看到"装完新版本数据全丢了、预设也重新乱掉"。
# 那一行代码跟别的属性长得一模一样，人工 review 抓不住，所以让机器守。
step "2.5/6  数据模型迁移安全"
if python3 scripts/check-model-migration.py > "/tmp/artstock-migration.log" 2>&1; then
    pass "$(grep -c '✅' /tmp/artstock-migration.log >/dev/null && echo '没有破坏迁移的模型改动')"
else
    fail "模型改动会破坏已有数据的迁移"
    grep -E '❌|⚠️' "/tmp/artstock-migration.log" | head -8 | sed 's/^/      /'
fi

# ───────────────────────────────────────────── 3. 解析器功能测试
step "3/6  纯逻辑回归测试（十二套）"
for suite in scan label textpreprocess paddleocr textbook sampler stock package taobao math model preset; do
    case "$suite" in
        scan)          LABEL="扫码解析器" ;;
        label)         LABEL="认字解析器" ;;
        textpreprocess) LABEL="喷码预处理" ;;
        paddleocr)     LABEL="PP-OCR 解码" ;;
        textbook)      LABEL="教材接口  " ;;
        sampler)       LABEL="取色算法  " ;;
        stock)         LABEL="采购结论  " ;;
        package)       LABEL="收包裹解析" ;;
        taobao)        LABEL="淘宝接入  " ;;
        math)          LABEL="补充装算术" ;;
        model)         LABEL="干燥模型  " ;;
        preset)        LABEL="预设色卡  " ;;
    esac
    if ./scripts/run-${suite}-tests.sh > "/tmp/artstock-${suite}.log" 2>&1; then
        SUMMARY=$(grep -E '^通过' "/tmp/artstock-${suite}.log" | tail -1)
        pass "${LABEL}  ${SUMMARY:-通过}"
    else
        fail "${LABEL} 测试失败"
        grep -E '❌' "/tmp/artstock-${suite}.log" | head -8 | sed 's/^/      /'
    fi
done

# ───────────────────────────────────────────── 4. 配置文件
step "4/6  配置文件合法性"

if command -v ruby >/dev/null 2>&1; then
    if ruby -ryaml -e 'YAML.load_file("project.yml"); YAML.load_file(".github/workflows/build-ipa.yml")' 2>/dev/null; then
        pass "project.yml 与 workflow 的 YAML 合法"
    else
        fail "YAML 解析失败"
    fi
else
    printf '%s   – 跳过 YAML 校验（没有 ruby）%s\n' "$DIM" "$RESET"
fi

if plutil -lint Resources/Info.plist >/dev/null 2>&1; then
    pass "Resources/Info.plist 合法"
else
    fail "Info.plist 不合法"
fi

ASSET_BAD=0
for j in $(find Resources -name 'Contents.json'); do
    python3 -c "import json,sys; json.load(open('$j'))" 2>/dev/null || { fail "JSON 非法：$j"; ASSET_BAD=1; }
done
[ "$ASSET_BAD" -eq 0 ] && pass "asset catalog 的 Contents.json 全部合法"

SH_BAD=0
for s in scripts/*.sh; do
    bash -n "$s" 2>/dev/null || { fail "shell 语法错误：$s"; SH_BAD=1; }
done
[ "$SH_BAD" -eq 0 ] && pass "scripts/*.sh 语法全部合法"

# ───────────────────────────────────────────── 5. 图标
step "5/6  App 图标合规性"
ICON="Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
if [ -f "$ICON" ]; then
    W=$(sips -g pixelWidth "$ICON" 2>/dev/null | awk '/pixelWidth/{print $2}')
    H=$(sips -g pixelHeight "$ICON" 2>/dev/null | awk '/pixelHeight/{print $2}')
    A=$(sips -g hasAlpha "$ICON" 2>/dev/null | awk '/hasAlpha/{print $2}')
    [ "$W" = "1024" ] && [ "$H" = "1024" ] && pass "尺寸 1024×1024" || fail "尺寸不对：${W}×${H}"
    [ "$A" = "no" ] && pass "不含 alpha 通道（App Store 要求）" \
                    || fail "带 alpha 通道，上传 App Store 会被拒（见 README 5.10）"
else
    fail "找不到 $ICON"
fi

# ───────────────────────────────────────────── 6. 真实编译（可选）
step "6/6  真实 xcodebuild 编译（需要 Xcode）"

DEVELOPER_PATH="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || echo '')}"
# 与 make-unsigned-ipa.sh 同步：允许版本化 Xcode 目录（Xcode_26.6.0.app），
# 否则 GitHub runner 上会被误判为"没有完整 Xcode"而跳过编译检查。
if ! printf '%s' "$DEVELOPER_PATH" | grep -q 'Xcode[^/]*\.app/Contents/Developer'; then
    printf '%s   – 跳过：没有可用的完整 Xcode。%s\n' "$DIM" "$RESET"
    printf '%s    设 DEVELOPER_DIR 或跑 sudo xcode-select -s 后即可自动启用此步。%s\n' "$DIM" "$RESET"
elif ! command -v xcodegen >/dev/null 2>&1; then
    printf '%s   – 跳过：找不到 xcodegen（生成 .xcodeproj 需要它）。%s\n' "$DIM" "$RESET"
else
    if xcodegen generate --spec project.yml >/dev/null 2>&1; then
        pass "xcodegen 生成 ArtStock.xcodeproj"
    else
        fail "xcodegen 生成工程失败"
    fi

    BUILD_LOG=$(mktemp)
    # ⚠️ 刻意**不写 `-sdk iphoneos`**：命令行上的 -sdk 是全局覆盖，
    #    会把嵌进来的手表 App 也按 iOS SDK 编译，`import WatchKit` 直接报错。
    #    只给 destination，Xcode 会按每个 target 的 platform 分派 SDK。
    if xcodebuild -project ArtStock.xcodeproj -scheme ArtStock \
         -configuration Release -destination 'generic/platform=iOS' \
         -derivedDataPath build/DerivedData \
         CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
         CODE_SIGN_IDENTITY="" CODE_SIGN_ENTITLEMENTS="" \
         build > "$BUILD_LOG" 2>&1; then
        ERRS=$(grep -cE 'error:' "$BUILD_LOG")
        WARNS=$(grep -cE 'warning:' "$BUILD_LOG")
        pass "xcodebuild 构建成功（error ${ERRS} / warning ${WARNS}）"
    else
        fail "xcodebuild 构建失败（详见 ${BUILD_LOG}）"
        grep -oE '[^ ]+\.swift:[0-9]+:[0-9]+: error: .*' "$BUILD_LOG" | sed 's|.*/ArtStock/||' | sort -u | head -15 | sed 's/^/      /'
    fi

    # 手表端单独编一遍。上面那次已经把嵌进 iOS App 的手表 App 一起编了，
    # 但**单独验证手表 scheme** 能抓出"只在 watchOS 上才有的错误"
    # （可用性标注、watchOS 独有的 API 限制），代价只有几秒。
    WATCH_LOG=$(mktemp)
    if xcodebuild -project ArtStock.xcodeproj -scheme ArtAssistWatch \
         -configuration Release -destination 'generic/platform=watchOS' \
         -derivedDataPath build/WatchDerivedData \
         CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
         CODE_SIGN_IDENTITY="" CODE_SIGN_ENTITLEMENTS="" \
         build > "$WATCH_LOG" 2>&1; then
        WERRS=$(grep -cE 'error:' "$WATCH_LOG")
        WWARNS=$(grep -cE 'warning:' "$WATCH_LOG")
        pass "手表端 xcodebuild 构建成功（error ${WERRS} / warning ${WWARNS}）"
    else
        fail "手表端构建失败（详见 ${WATCH_LOG}）"
        grep -oE '[^ ]+\.swift:[0-9]+:[0-9]+: error: .*' "$WATCH_LOG" | sed 's|.*/ArtStock/||' | sort -u | head -15 | sed 's/^/      /'
    fi

    # 嵌入关系也要验一下：手表 App 必须真的在 iOS App 的 Watch/ 目录里，
    # 否则"支持 Apple Watch"只是工程文件里的一句话。
    WATCH_APP="build/DerivedData/Build/Products/Release-iphoneos/ArtStock.app/Watch/ArtAssistWatch.app/ArtAssistWatch"
    if [ -f "$WATCH_APP" ]; then
        pass "手表 App 已嵌进 iOS App（Watch/ArtAssistWatch.app）"
    else
        fail "iOS App 里没有找到嵌入的手表 App（$WATCH_APP）"
    fi
fi

# ───────────────────────────────────────────── 结果
printf '\n%s══════════════════════════════════════════════════════════%s\n' "$BOLD" "$RESET"
if [ ${#FAILED[@]} -eq 0 ]; then
    printf '%s  ✅ 全部通过%s\n' "$GREEN$BOLD" "$RESET"
    exit 0
else
    printf '%s  ❌ %d 项失败%s\n' "$RED$BOLD" "${#FAILED[@]}" "$RESET"
    for f in "${FAILED[@]}"; do printf '     · %s\n' "$f"; done
    exit 1
fi
