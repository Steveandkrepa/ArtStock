#!/usr/bin/env bash
#
# 把 App 编译并装进 iPad 模拟器，直接打开给你试。
#
# 为什么要这个：出 IPA 要下载 → SideStore 签名 → 装 → 试，
# 一轮下来几分钟。改一行 UI 也走这一整套太浪费。
# 模拟器这条路上一步到位，改完直接看效果；确认没问题了再出 IPA。
#
# 用法：
#   ./scripts/run-in-simulator.sh                      # 默认 iPad Pro 13-inch (M5)
#   ./scripts/run-in-simulator.sh "iPad mini (A17 Pro)"  # 换一台
#   ./scripts/run-in-simulator.sh --fresh              # 先卸载（清空 App 数据）
#   ./scripts/run-in-simulator.sh --shot               # 顺手截一张图到 /tmp
#   ./scripts/run-in-simulator.sh --list               # 看有哪些可用机型
#
# ⚠️ 模拟器**测不了**的东西（这些只能在真机上验）：
#   · 相机扫码（模拟器没有摄像头）
#   · Apple Pencil 的压感/倾斜/双击（只有真笔有）
#   · 通知、画中画、后台存活、LiveContainer
#   · 真机性能（模拟器跑在 Mac 上，比真机快）
#   能测的：全部界面与交互、SwiftData 存取、网页登录/抓取、
#   到货推算、库存算术、导入导出、深色模式与各机型尺寸。
#

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# 没设 DEVELOPER_DIR 时 simctl 可能找不到运行时，显式给一个
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# xcodegen 不在 PATH 里时从项目里记的路径取（跟其它脚本一致）
if ! command -v xcodegen >/dev/null 2>&1; then
    GEN_PATH_FILE="$ROOT/../.tools/XCODEGEN_PATH"
    if [ -f "$GEN_PATH_FILE" ]; then
        export PATH="$(dirname "$(cat "$GEN_PATH_FILE")"):$PATH"
    fi
fi

if [ "${1:-}" = "--list" ]; then
    echo "==> 可用的 iPad 模拟器："
    xcrun simctl list devices available | sed -n '/-- iOS/,/-- /p' | grep -i "iPad" \
        | sed 's/^[[:space:]]*/  /; s/ ([0-9A-F-]\{36\})//'
    exit 0
fi

FRESH=0
SHOT=0
DEVICE=""
for arg in "$@"; do
    case "$arg" in
        --fresh) FRESH=1 ;;
        --shot) SHOT=1 ;;
        --list) ;;
        *) DEVICE="$arg" ;;
    esac
done
DEVICE="${DEVICE:-iPad Pro 13-inch (M5)}"

BUNDLE_ID="com.yuanjunhao.artstock"

# ── 1. 找设备 ──────────────────────────────────────────────
UDID=$(xcrun simctl list devices available | grep -F "$DEVICE (" | head -1 \
        | sed -n 's/.*(\([0-9A-F-]\{36\}\)).*/\1/p')
if [ -z "$UDID" ]; then
    echo "❌ 找不到模拟器：$DEVICE" >&2
    echo "   用 --list 看可用机型。" >&2
    exit 1
fi
echo "==> 目标模拟器：$DEVICE ($UDID)"

# ── 2. 生成工程 ────────────────────────────────────────────
if command -v xcodegen >/dev/null 2>&1; then
    xcodegen generate --spec project.yml >/dev/null
    echo "==> 已重新生成 ArtStock.xcodeproj"
fi

# ── 3. 编译（模拟器版，Debug 更快）─────────────────────────
# ⚠️ 用 get-task-allow 之类的签名设置对模拟器无意义，直接关掉签名。
echo "==> 编译 iPad 模拟器版本（Debug，增量）"
xcodebuild -project ArtStock.xcodeproj -scheme ArtStock \
    -configuration Debug -sdk iphonesimulator \
    -destination "id=$UDID" \
    -derivedDataPath build/SimDerivedData \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" CODE_SIGN_ENTITLEMENTS="" \
    build > /tmp/artstock-sim-build.log 2>&1 || {
        echo "❌ 编译失败，最后 30 行：" >&2
        grep -E "error:|warning:" /tmp/artstock-sim-build.log | head -20 >&2
        tail -10 /tmp/artstock-sim-build.log >&2
        exit 1
    }
APP="build/SimDerivedData/Build/Products/Debug-iphonesimulator/ArtStock.app"
[ -d "$APP" ] || { echo "❌ 编译产物不在 $APP" >&2; exit 1; }
ERRS=$(grep -cE "error:" /tmp/artstock-sim-build.log || true)
WARNS=$(grep -cE "warning:" /tmp/artstock-sim-build.log || true)
echo "   ✓ 编译成功（error ${ERRS} / warning ${WARNS}）"

# 从产物里读 bundle id，别在脚本里写死
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Info.plist")
echo "   ✓ Bundle ID：$BUNDLE_ID"

# ── 4. 开机 ────────────────────────────────────────────────
if xcrun simctl list devices | grep -F "$UDID" | grep -q "Booted"; then
    echo "==> 模拟器已在运行"
else
    echo "==> 启动模拟器"
    xcrun simctl boot "$UDID" 2>/dev/null || true
fi
# ⚠️ 这台机器上 `open -a Simulator` 会失败：Xcode 是精简过的，
#    Contents/Developer/Applications/Simulator.app 根本不存在，
#    取而代之的是新的 DeviceHub.app（Xcode 26+ 的设备界面）。
#    所以按优先级挨个试，最后一个都不行也**不算错误** ——
#    App 已经在模拟器里跑起来了，只是没有可见窗口。
SIM_GUI=""
for candidate in \
    "$(xcode-select -p)/Applications/Simulator.app" \
    "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app" \
    "/Applications/Simulator.app"
do
    [ -d "$candidate" ] && { SIM_GUI="$candidate"; break; }
done
if [ -z "$SIM_GUI" ]; then
    for candidate in \
        "$(xcode-select -p)/Applications/DeviceHub.app" \
        "/Applications/Xcode.app/Contents/Applications/DeviceHub.app"
    do
        [ -d "$candidate" ] && { SIM_GUI="$candidate"; break; }
    done
fi

if [ -n "$SIM_GUI" ]; then
    echo "==> 打开设备界面：$(basename "$SIM_GUI")"
    open "$SIM_GUI" --args -CurrentDeviceUDID "$UDID" || true
else
    echo "   – 找不到模拟器界面 App，App 只在后台跑（用 --shot 截图看）"
fi
# 等它真的 booted（装包太快会失败）
for _ in $(seq 1 30); do
    xcrun simctl list devices | grep -F "$UDID" | grep -q "Booted" && break
    sleep 1
done

# ── 5. 装上去 ──────────────────────────────────────────────
if [ "$FRESH" -eq 1 ]; then
    echo "==> --fresh：先卸载（会清掉模拟器里的 App 数据）"
    xcrun simctl uninstall "$UDID" "$BUNDLE_ID" 2>/dev/null || true
fi
echo "==> 安装"
xcrun simctl install "$UDID" "$APP"

# ── 6. 打开 ────────────────────────────────────────────────
echo "==> 启动"
xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null

if [ "$SHOT" -eq 1 ]; then
    # ⚠️ Debug 冷启动要几秒才渲染完，2 秒会截到全白 —— 别被它误导成"App 挂了"
    sleep 6
    xcrun simctl io "$UDID" screenshot /tmp/artassist-sim.png >/dev/null 2>&1 \
        && echo "==> 截图：/tmp/artassist-sim.png"
fi

cat <<EOF

✅ 已经装到「${DEVICE}」并打开了。

   App 里看到的数据是**模拟器独立的**，跟你 iPad 上的真机数据无关，
   所以在模拟器里乱点、清空数据都不会影响你的真机。

   看日志（App 崩了/行为奇怪时用）：
     export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
     xcrun simctl spawn $UDID log stream --level debug \\
       --predicate 'processImagePath CONTAINS "ArtStock"'

   截一张当前画面（不用开界面也能看）：
     export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
     xcrun simctl io $UDID screenshot /tmp/sim.png

   改完代码重新装一遍（增量，几秒）：
     ./scripts/run-in-simulator.sh

   想清掉模拟器里的 App 数据重来：
     ./scripts/run-in-simulator.sh --fresh

   试好了再出 IPA：
     ./scripts/make-unsigned-ipa.sh
EOF
