#!/usr/bin/env bash
#
# ============================================================================
#  ArtStock — 未签名 IPA 构建脚本
#  ---------------------------------------------------------------------------
#  产出：一个 **完全没有签名** 的 .ipa（内部没有 _CodeSignature/、没有
#        embedded.mobileprovision），可以直接丢给 SideStore 用免费 Apple ID 重签。
#
#  用法：
#      scripts/make-unsigned-ipa.sh [scheme] [configuration] [output.ipa]
#
#  参数（全部可选）：
#      scheme         默认 ArtStock
#      configuration  默认 Release
#      output.ipa     默认 build/ArtAssist-<configuration>-<时间戳>.ipa
#
#  示例：
#      scripts/make-unsigned-ipa.sh
#      scripts/make-unsigned-ipa.sh ArtStock Release /tmp/ArtStock.ipa
#      CONFIGURATION=Debug scripts/make-unsigned-ipa.sh
#
#  环境变量（可选）：
#      DERIVED_DATA   覆盖 DerivedData 目录，默认 <仓库根>/build/DerivedData
#
#  前置条件：
#      · 已安装 Xcode（不是只有 Command Line Tools）
#        —— 需要 iOS SDK；本项目用到 iOS 26 SDK 里的符号，
#           SDK 太老会在 DesignSystem/LiquidGlass.swift 报错。
#      · 已安装 XcodeGen：brew install xcodegen
#
#  ⚠️ 关于签名：本脚本**故意**把签名全部关掉。产物未签名是设计目标，
#     不是配置错误。若你需要一个已签名的包，请改用：
#        xcodebuild ... CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM=<TeamID> build
#     详见项目根目录 project.yml 末尾的「如何恢复签名」注释。
# ============================================================================

set -euo pipefail

# ---------------------------------------------------------------- 输出美化
readonly C_RESET=$'\033[0m'
readonly C_BOLD=$'\033[1m'
readonly C_BLUE=$'\033[34m'
readonly C_GREEN=$'\033[32m'
readonly C_YELLOW=$'\033[33m'
readonly C_RED=$'\033[31m'

step()  { printf '%s==> %s%s\n' "$C_BLUE$C_BOLD" "$*" "$C_RESET"; }
info()  { printf '    %s\n' "$*"; }
ok()    { printf '%s  ✓ %s%s\n' "$C_GREEN" "$*" "$C_RESET"; }
warn()  { printf '%s  ! %s%s\n' "$C_YELLOW" "$*" "$C_RESET"; }
die()   { printf '%s  ✗ %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; exit 1; }

# ---------------------------------------------------------------- 参数解析
usage() {
    cat <<'EOF'
ArtStock — 未签名 IPA 构建脚本

用法：
    scripts/make-unsigned-ipa.sh [scheme] [configuration] [output.ipa]

参数（全部可选）：
    scheme         默认 ArtStock
    configuration  默认 Release
    output.ipa     默认 build/ArtStock-<configuration>-<时间戳>.ipa
                   相对路径按「当前工作目录」解析

环境变量（可选）：
    DERIVED_DATA   覆盖 DerivedData 目录，默认 <仓库根>/build/DerivedData

示例：
    scripts/make-unsigned-ipa.sh
    scripts/make-unsigned-ipa.sh ArtStock Release /tmp/ArtStock.ipa
    scripts/make-unsigned-ipa.sh ArtStock Debug ./ArtStock-debug.ipa

前置条件：
    · 完整 Xcode（不只是 Command Line Tools），需要 iOS SDK
    · XcodeGen：brew install xcodegen

产物：
    一个完全未签名的 .ipa（无 _CodeSignature/、无 embedded.mobileprovision），
    可直接交给 SideStore 用免费 Apple ID 重签安装。
EOF
    exit 0
}

case "${1:-}" in
    -h|--help|help) usage ;;
esac

SCHEME="${1:-ArtStock}"
CONFIGURATION="${2:-Release}"

# ---------------------------------------------------------------- 路径解析
# 脚本可能被任意 cwd 调用，所以一切路径都相对脚本自己所在目录推导。
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

PROJECT_FILE="$PROJECT_ROOT/ArtStock.xcodeproj"
SPEC_FILE="$PROJECT_ROOT/project.yml"
DERIVED_DATA="${DERIVED_DATA:-$PROJECT_ROOT/build/DerivedData}"
STAGING_DIR="$PROJECT_ROOT/build/ipa-staging"

TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
OUTPUT_ARG="${3:-build/ArtAssist-${CONFIGURATION}-${TIMESTAMP}.ipa}"

# 把相对输出路径按「当前工作目录」解析成绝对路径（而不是相对仓库根），
# 这样 `scripts/... /tmp/x.ipa` 与 `scripts/... out.ipa` 两种写法都符合直觉。
case "$OUTPUT_ARG" in
    /*) OUTPUT_IPA="$OUTPUT_ARG" ;;
    *)  OUTPUT_IPA="$(pwd)/$OUTPUT_ARG" ;;
esac

printf '\n%s╔══════════════════════════════════════════════════════════╗%s\n' "$C_BOLD" "$C_RESET"
printf '%s║  ArtStock — 构建未签名 IPA                               ║%s\n' "$C_BOLD" "$C_RESET"
printf '%s╚══════════════════════════════════════════════════════════╝%s\n\n' "$C_BOLD" "$C_RESET"
info "仓库根目录 : $PROJECT_ROOT"
info "scheme     : $SCHEME"
info "配置       : $CONFIGURATION"
info "输出       : $OUTPUT_IPA"
printf '\n'

# ============================================================ 1. 依赖检查
step "[1/7] 检查构建依赖"

if ! command -v xcodebuild >/dev/null 2>&1; then
    die "找不到 xcodebuild。请安装完整 Xcode（Command Line Tools 不够，没有 iOS SDK）。

       安装：App Store 搜索 Xcode，或 https://developer.apple.com/download/all/
       装完后执行：sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
fi

# 关键前置检查：只装了 Command Line Tools 时，/usr/bin/xcodebuild 这个文件是存在的，
# 但一执行就报 "requires Xcode, but active developer directory is a command line
# tools instance" 并退出 1。必须在这里拦下来给出可操作的提示，
# 否则脚本会停在一句看不懂的 xcodebuild 报错上。
#
# 同时尊重 DEVELOPER_DIR：这是 Apple 官方的工具链覆盖机制，且**不需要 sudo**。
# 没装过 sudo 权限或在 CI 里不方便跑 `xcode-select -s` 时，可以这样绕过：
#     DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/make-unsigned-ipa.sh
# 只检查 `xcode-select -p` 会把这种情况误判成"没装 Xcode"。
DEVELOPER_PATH="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || echo '')}"
if ! printf '%s' "$DEVELOPER_PATH" | grep -q 'Xcode.app/Contents/Developer'; then
    die "当前命令行工具指向的不是完整 Xcode，因此没有 iOS SDK，无法构建 iOS App。

       xcode-select -p  →  ${DEVELOPER_PATH:-<取不到>}

       四种处理方式（任选）：
         1) 本地装 Xcode：
              · App Store 搜索 Xcode，或到 https://developer.apple.com/download/all/ 下载
              · 装完后执行：sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
              · 重新运行本脚本
         2) 不想用 sudo，就设 DEVELOPER_DIR 覆盖（Apple 官方机制，等价且无需 root）：
              export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
              ./scripts/make-unsigned-ipa.sh
         3) 用 GitHub Actions 云端构建（本机不装 Xcode）：
              把仓库推到 GitHub，工作流 .github/workflows/build-ipa.yml 会自动出未签名 IPA
         4) 换一台装了 Xcode 的 Mac 跑本脚本"
fi
info "developer dir: $DEVELOPER_PATH"

if ! XCODEBUILD_VERSION="$(xcodebuild -version 2>&1)"; then
    die "xcodebuild 执行失败（xcode-select 已指向 Xcode，但工具链仍然报错）：

$(printf '%s\n' "$XCODEBUILD_VERSION" | sed 's/^/       /')"
fi
printf '%s\n' "$XCODEBUILD_VERSION" | sed 's/^/    /'

# SDK 版本提示（不是硬失败）：
# 源码里的 iOS 26 API（glassEffect 等）被 `#if compiler(>=6.2)` 整块门控，
# 用老工具链编译时那一整块会被跳过、自动退化为材质外观，所以老 SDK 依然能出包，
# 只是拿不到 iOS 26 的液态玻璃。这里只提醒，不阻断。
IOS_SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || echo '')"
if [ -z "$IOS_SDK_VERSION" ]; then
    warn "取不到 iphoneos SDK 版本（xcrun --sdk iphoneos --show-sdk-version 失败），继续尝试构建。"
else
    info "iphoneos SDK: $IOS_SDK_VERSION"
    SDK_MAJOR="${IOS_SDK_VERSION%%.*}"
    case "$SDK_MAJOR" in
        ''|*[!0-9]*) : ;;
        *)
            if [ "$SDK_MAJOR" -lt 26 ]; then
                warn "当前 iOS SDK 是 ${IOS_SDK_VERSION}（< 26）。"
                warn "iOS 26 的液态玻璃 API 会被 #if compiler(>=6.2) 门控整体跳过，"
                warn "App 会自动退化为材质降级外观 —— 仍可正常构建与运行，只是没有新外观。"
            fi
            ;;
    esac
fi

if ! command -v xcodegen >/dev/null 2>&1; then
    die "找不到 xcodegen。本工程用 XcodeGen 管理工程文件，请先安装：

       brew install xcodegen

       如果连 Homebrew 都没有，先装 Homebrew：
       /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"

       装好后重新运行本脚本即可。"
fi
info "xcodegen   : $(xcodegen --version 2>&1)"

[ -f "$SPEC_FILE" ] || die "找不到工程描述文件：$SPEC_FILE"
ok "依赖检查通过"

# ============================================================ 2. 生成工程
step "[2/7] 用 XcodeGen 生成 ArtStock.xcodeproj"
info "spec: $SPEC_FILE"
# 每次都重新生成：project.yml 才是唯一事实来源，
# 不要让仓库里的 .xcodeproj 存在"手工改过但没同步"的状态。
( cd "$PROJECT_ROOT" && xcodegen generate --spec project.yml )
[ -d "$PROJECT_FILE" ] || die "xcodegen 执行完了但没生成 $PROJECT_FILE"
ok "工程已生成：$PROJECT_FILE"

# ============================================================ 3. 构建
step "[3/7] xcodebuild 构建（签名全部关闭）"

# 这些设置会同时传给 build 与 -showBuildSettings 两次调用，
# 保证两次解析出来的 BUILT_PRODUCTS_DIR 是同一个目录。
#
# ⚠️ **刻意不写 `-sdk iphoneos`。**
#    命令行上的 `-sdk` 是**全局覆盖**：它会把手表 target 也按 iOS SDK 编译，
#    于是那句 `import WatchKit` 直接报
#        Unable to resolve module dependency: 'WatchKit'
#    而手表 App 是嵌在 iOS App 里的（Watch/ 目录），必须一起构建。
#    只用 `-destination 'generic/platform=iOS'` 时，Xcode 会按每个 target
#    自己的 platform 分派 SDK（iOS target 用 iphoneos、手表用 watchos），
#    这才是嵌入 watch app 的正确构建方式。
BUILD_ARGS=(
    -project "$PROJECT_FILE"
    -scheme "$SCHEME"
    -configuration "$CONFIGURATION"
    -destination 'generic/platform=iOS'
    -derivedDataPath "$DERIVED_DATA"
    CODE_SIGNING_ALLOWED=NO
    CODE_SIGNING_REQUIRED=NO
    CODE_SIGN_IDENTITY=""
    CODE_SIGN_ENTITLEMENTS=""
)

info "sdk        : 由 destination 分派（iOS target → iphoneos，手表 target → watchos）"
info "derivedData: $DERIVED_DATA"
info "签名       : CODE_SIGNING_ALLOWED=NO / CODE_SIGNING_REQUIRED=NO / CODE_SIGN_IDENTITY=\"\""
printf '\n'

# 不签名 + 不做 codesign 校验，构建日志会干净很多。
mkdir -p "$DERIVED_DATA"
xcodebuild "${BUILD_ARGS[@]}" build

# ============================================================ 4. 定位产物
step "[4/7] 从 -showBuildSettings 读取真实的产物路径"

# 刻意不硬编码 DerivedData / Products 目录：
# 不同 Xcode 版本、不同 -derivedDataPath、不同 configuration 都会改变它，
# 唯一可靠的来源是 Xcode 自己报出来的 build settings。
BUILD_SETTINGS="$(xcodebuild "${BUILD_ARGS[@]}" -showBuildSettings 2>/dev/null)"

read_setting() {
    # 取最后一次出现的值（target 级会覆盖 project 级）；
    # sub() 只裁掉第一个 "=" 之前的部分，所以取值里含 "=" 也不会被截断。
    printf '%s\n' "$BUILD_SETTINGS" \
        | awk -v key="$1" '
            $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
                sub(/^[[:space:]]*[^=]*=[[:space:]]*/, "", $0)
                print
            }' \
        | tail -n 1
}

BUILT_PRODUCTS_DIR="$(read_setting BUILT_PRODUCTS_DIR)"
FULL_PRODUCT_NAME="$(read_setting FULL_PRODUCT_NAME)"
EXECUTABLE_NAME="$(read_setting EXECUTABLE_NAME)"

[ -n "$BUILT_PRODUCTS_DIR" ] || die "-showBuildSettings 里没拿到 BUILT_PRODUCTS_DIR"
[ -n "$FULL_PRODUCT_NAME" ]  || die "-showBuildSettings 里没拿到 FULL_PRODUCT_NAME"
[ -n "$EXECUTABLE_NAME" ]    || die "-showBuildSettings 里没拿到 EXECUTABLE_NAME"

APP_PATH="$BUILT_PRODUCTS_DIR/$FULL_PRODUCT_NAME"
info "BUILT_PRODUCTS_DIR : $BUILT_PRODUCTS_DIR"
info "FULL_PRODUCT_NAME  : $FULL_PRODUCT_NAME"

# 注意：可执行文件名是 EXECUTABLE_NAME（ArtStock），
# 不是 FULL_PRODUCT_NAME（ArtStock.app）—— 少写这层会误判成"产物不完整"。
[ -d "$APP_PATH" ] || die "构建报告成功，但找不到 .app：$APP_PATH"
[ -f "$APP_PATH/$EXECUTABLE_NAME" ] || die ".app 里没有可执行文件：$APP_PATH/$EXECUTABLE_NAME"
[ -f "$APP_PATH/Info.plist" ] || die ".app 里没有 Info.plist：$APP_PATH/Info.plist"
ok "已定位到 .app：$APP_PATH"

# ============================================================ 5. 签名校验
step "[5/7] 校验产物确实「未签名」"

SIGN_FAILED=0
if [ -d "$APP_PATH/_CodeSignature" ]; then
    warn "$APP_PATH/_CodeSignature 存在 —— 产物被签过名了！"
    warn "SideStore 需要未签名 IPA 才能用免费 Apple ID 重签。"
    warn "请确认构建命令里带了：CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=\"\""
    SIGN_FAILED=1
else
    ok "没有 _CodeSignature 目录（符合预期）"
fi

if [ -f "$APP_PATH/embedded.mobileprovision" ]; then
    warn "$APP_PATH/embedded.mobileprovision 存在 —— 包里带了描述文件，不是纯净的未签名包。"
    SIGN_FAILED=1
else
    ok "没有 embedded.mobileprovision（符合预期）"
fi

if [ "$SIGN_FAILED" -ne 0 ]; then
    die "产物不是未签名包，已中止。请检查 project.yml / 命令行里的签名设置。"
fi

# 顺手把关键信息打出来，出问题时一眼能看出 SDK / 最低系统版本对不对。
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$APP_PATH/Info.plist" 2>/dev/null || echo '未知')"
SDK_NAME="$(/usr/libexec/PlistBuddy -c 'Print :DTSDKName' "$APP_PATH/Info.plist" 2>/dev/null || echo '未知')"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Info.plist" 2>/dev/null || echo '未知')"
DISPLAY_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP_PATH/Info.plist" 2>/dev/null || echo '未知')"
info "Bundle ID        : $BUNDLE_ID"
info "显示名           : $DISPLAY_NAME"
info "MinimumOSVersion : $MIN_OS"
info "构建用 SDK       : $SDK_NAME"

APP_SIZE="$(du -sh "$APP_PATH" | awk '{print $1}')"
info "未压缩体积       : $APP_SIZE"

# ============================================================ 6. 组装 IPA
step "[6/7] 组装 Payload 并打包成 .ipa"

# Payload/<App>.app 是 IPA 唯一合法的内部结构。
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR/Payload"
# 用 ditto 而不是 cp -R：ditto 会正确保留扩展属性、符号链接与资源分支，
# 这些在 iOS 包里有意义（cp -R 在极少数情况下会丢掉信息）。
ditto "$APP_PATH" "$STAGING_DIR/Payload/$FULL_PRODUCT_NAME"
info "Payload/$FULL_PRODUCT_NAME"

mkdir -p "$(dirname -- "$OUTPUT_IPA")"
rm -f "$OUTPUT_IPA"
# -X 不写入 Mac 的扩展属性，避免解压端出现 __MACOSX 垃圾目录。
( cd "$STAGING_DIR" && zip -qry -X "$OUTPUT_IPA" Payload )

[ -f "$OUTPUT_IPA" ] || die "打包失败，没有生成 $OUTPUT_IPA"
ok "IPA 已生成"

# ============================================================ 7. 结果汇报
step "[7/7] 完成"

IPA_BYTES="$(stat -f%z "$OUTPUT_IPA" 2>/dev/null || echo 0)"
IPA_HUMAN="$(du -h "$OUTPUT_IPA" | awk '{print $1}')"

printf '\n%s┌──────────────────────────────────────────────────────────┐%s\n' "$C_GREEN" "$C_RESET"
printf '%s│  ✅ 未签名 IPA 构建成功                                   │%s\n' "$C_GREEN$C_BOLD" "$C_RESET"
printf '%s└──────────────────────────────────────────────────────────┘%s\n\n' "$C_GREEN" "$C_RESET"
info "绝对路径 : $OUTPUT_IPA"
info "文件大小 : $IPA_HUMAN  ($IPA_BYTES 字节)"
info "配置     : $CONFIGURATION"
printf '\n'
printf '%s  下一步：把这个 ipa 传到 iPad，用 SideStore 打开安装。%s\n' "$C_BOLD" "$C_RESET"
printf '\n'
info "· 传输方式：AirDrop 到 iPad / 存进「文件」App / 走 iCloud 云盘 / 自建 HTTP 都行。"
info "· 安装方式：在 iPad 的「文件」里点这个 .ipa → 选 SideStore 打开 → 签名安装。"
info "· 免费 Apple ID 限制：证书 7 天过期，需要回到 SideStore 续签；"
info "  同时最多只能装 3 个自签 App。"
printf '\n'

# 顺手做个结构自检，把 IPA 里的顶层结构打出来，方便和预期对照：
# 期望恰好是 Payload/ArtStock.app/…，不该出现 __MACOSX 之类的东西。
info "IPA 内顶层结构："
unzip -Z1 "$OUTPUT_IPA" 2>/dev/null | awk -F/ 'NF<=3' | sed 's/^/    /' | head -20 || true
printf '\n'
