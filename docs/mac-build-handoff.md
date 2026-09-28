# ArtStock — Mac Worker 构建交接说明（方案 A）

> 本文档是「Agent Host（本 Ubuntu VM）→ Mac Worker（远程 macOS）出未签名 IPA」的
> 操作手册，写给驱动 hermes-mac-bridge 的 Agent 会话直接用。
> 构建目标：`com.yuanjunhao.artstock`（ArtAssist），未签名 IPA → SideStore 自签安装。

---

## 0. 架构一句话

```
Agent Host (本机 DSH + hermes 桥, 9443)
        │  mac.* 工具（mac.execute / mac.xcode_build …）
        ▼
Mac Worker (远程 macOS, 拉模式 HTTPS JSON)
        │  GitSync 拉代码 → 预检 → xcodegen → xcodebuild → 组装 IPA
        ▼
产物: 未签名 .ipa（无 _CodeSignature / 无 embedded.mobileprovision）
```

## 1. 两个硬前置条件（不满足一定失败）

### 1.1 Git 基线已提交，Mac 能克隆到

桥的 GitSync 用 `git clone <repository> .` 拉代码，**空仓库 / 无提交 = 无法克隆**。

- 仓库已建立首个基线提交（`main`，含全部源码 + .gitignore 排除 build/.build-cache/.xcodeproj）
- Mac 需要能访问的 URL：局域网内本机 IP `192.168.0.142`（Agent Host）起一个 git http
  裸仓库，或推到 GitHub 私有仓库。仓库当前无 remote —— 用桥之前需要先决定并配置 URL。

### 1.2 桥需开启 `commandPolicy.allowRestricted`

`mac.execute` 对命令做分级：

| 工具 | 分类 | 默认能否执行 |
|---|---|---|
| `xcodebuild build/test` | DEVELOPMENT | ✅ 能（`mac.xcode_build` 直接可用） |
| `xcode-select` / `plutil` / `ls`… | SAFE | ✅ 能 |
| `xcodegen` / `bash` / `ditto` / `zip` / `git push`… | RESTRICTED | ❌ 需 `allowRestricted: true` |

> 因此走「一键脚本」路径必须开：
> ```json
> { "commandPolicy": { "allowRestricted": true } }
> ```
> 这是桥的配置项，由 hermes 会话在激活时设置。若出于安全不想开，见第 3 节「分步路径」。

## 2. 推荐路径：一键脚本（最省事，结果机器可读）

仓库已提供 `scripts/mac-worker-build.sh`：
- 预检（Xcode / xcodegen / iOS SDK）→ 调 `make-unsigned-ipa.sh` → 定位产物
- **stdout 输出单行 JSON**（status / ipa_path / ipa_bytes / xcode_version / ios_sdk_version），
  日志走 stderr，桥可直接透传解析

### 2.1 先确认 Mac Worker 在线且具备能力

```json
// mac.status
{ "worker_id": "mac-worker-001" }
// 期望: status=ONLINE, capabilities 含 xcode/swift/git

// mac.system_info (可选，确认 Xcode 版本)
{ "worker_id": "mac-worker-001", "refresh": true, "wait_timeout_s": 30 }
```

### 2.2 推送代码（经桥的 git 通道，若已配 repository）

```json
// 让 GitSync 把仓库 sync 到指定 commit/branch（以下二选一）
{ "repository": "<Mac 可访问的仓库 URL>", "branch": "main" }
```

### 2.3 一键出包

```json
// mac.execute
{
  "tool": "bash",
  "args": ["scripts/mac-worker-build.sh", "ArtStock", "Release"],
  "cwd": "<Mac 上 checkout 出来的 ArtStock 目录>",
  "timeout_s": 1800,
  "wait_timeout_s": 900
}
```

成功响应（`status=SUCCESS`，`stdout` 含 JSON）：

```json
{ "status": "ok", "ipa_path": "/…/ArtStock/build/ArtAssist-Release-<时间戳>.ipa",
  "ipa_bytes": 1366000, "xcode_version": "27.0", "ios_sdk_version": "27.0" }
```

## 3. 分步路径（不开 allowRestricted 时）

全部走 DEVELOPMENT/SAFE 通道，但组装 IPA 那两步（ditto/zip）仍需解释器——
若完全不开 restricted，则**无法产出 .ipa**，只能到 .app。给两个子选项：

### 3.1 只生成工程 + 编译（能到 .app）

```json
// 1) xcodegen 生成工程（xcodegen 是 RESTRICTED，不开 allowRestricted 则此步被拒）
//    若不能开，需在仓库里预生成 .xcodeproj 并提交（当前 .gitignore 忽略它，见 3.3）

// 2) mac.xcode_build —— DEVELOPMENT，默认可用
{
  "project": "<repo>/ArtStock.xcodeproj",
  "scheme": "ArtStock",
  "configuration": "Release",
  "destination": "generic/platform=iOS",
  "extra_args": [
    "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO",
    "CODE_SIGN_IDENTITY=", "CODE_SIGN_ENTITLEMENTS="
  ],
  "timeout_s": 1800
}
```

> ⚠️ **必须用 `-destination 'generic/platform=iOS'`，不要用 `-sdk iphoneos`。**
> `-sdk` 是全局覆盖，会把嵌进 iOS App 的手表 target 也按 iOS SDK 编译，
> 导致 `import WatchKit` 报错。只用 destination 时 Xcode 按 target 分派 SDK。

### 3.2 组装 IPA（需要 ditto + zip，都是 RESTRICTED）

在 `.app` 构建成功后，仍需把 `Payload/<App>.app` 压成 `.ipa`。这两个命令
默认被 RESTRICTED 拦。**结论：分步路径若不开 allowRestricted，到不了 .ipa。**
建议直接走第 2 节一键脚本。

### 3.3 备选：预生成并提交 .xcodeproj

若确实不能开 restricted 且想用 `mac.xcode_build`：
- 在本机用 `xcodegen generate` 生成 `ArtStock.xcodeproj/`，临时从 .gitignore 移除
  `ArtStock.xcodeproj/` 一行后提交。
- ⚠️ 这违背项目「.xcodeproj 是产物不入库」的约定，只在万不得已时用。

## 4. 构建注意点（踩过的坑，务必遵守）

| 事项 | 说明 |
|---|---|
| **签名** | 必须传 `CODE_SIGNING_ALLOWED=NO` 等四件套；不带会走正常签名流程报错 |
| **destination** | 用 `generic/platform=iOS`，绝不写 `-sdk iphoneos`（手表 target 会被错编） |
| **iOS 26 液态玻璃** | `LiquidGlass.swift` 被 `#if compiler(>=6.2)` 门控；SDK<26 自动退化材质外观，**仍能出包**，不是错误 |
| **Scheme** | 工程有 shared scheme（`ArtStock` / `ArtAssistWatch`），headless 下 `xcodebuild -scheme ArtStock` 可用 |
| **xcodegen** | `project.yml` 是唯一事实来源；`.xcodeproj` 被 .gitignore 忽略，每次构建前必须 generate |
| **产物路径** | 脚本用 `-showBuildSettings` 动态定位，不要硬编码 DerivedData 路径 |

## 5. 验证与取回产物

### 5.1 验证未签名（可选，脚本已内置校验）

```json
// mac.execute：确认包里没有签名痕迹
{ "tool": "plutil", "args": ["-p", "<repo>/build/…/ArtStock.app/Info.plist"], "cwd": "<repo>" }
// 或 ls 检查无 _CodeSignature / embedded.mobileprovision
{ "tool": "ls", "args": ["-la", "<repo>/build/…/ArtStock.app"] }
```

### 5.2 取回 .ipa

桥当前**没有文件下载通道**（纯任务拉模式）。三种取回方式：

1. **Agent Host 起 HTTP 服务**：Mac 上 `python3 -m http.server` 指向 build/ 目录，
   Agent 从 `http://<mac-ip>:<port>/…ipa` 用 web_fetch/下载拉回本工作区。
   （命令策略里 `python3` 是 RESTRICTED，需 allowRestricted。）
2. **airdrop/网盘人工**：输出路径后由人工 AirDrop 到 iPad（本来就是最终去向）。
3. **桥后续加 download 工具**（v2 增强）：交给 hermes 会话规划。

## 6. 本机侧已完成的验证（接手基线）

在写本文档之前，本机已用 Python 补齐 verify-all.sh 里非 Xcode 的部分：

| 检查 | 结果 |
|---|---|
| 跨文件接口一致性（check-consistency.py，579 处成员引用 + 122 处 init 标签） | ✅ |
| 模型迁移安全（check-model-migration.py，11 实体对基线） | ✅ |
| project.yml / workflow YAML 合法性 | ✅ |
| Info.plist（两份）plist 合法性 | ✅ |
| 5 个 asset catalog Contents.json | ✅ |
| 18 个 shell 脚本语法 | ✅ |
| 2 个 AppIcon 1024×1024 无 alpha | ✅ |
| project.yml 引用路径全部存在 | ✅ |

**本机无法做（留给 Mac Worker）**：`swiftc -parse`（无 Swift 工具链）、
12 套纯逻辑回归（需要 swiftc）、真实 xcodebuild 编译、XcodeGen 生成。

## 7. 速查：Mac 上最终要发生的事

```bash
cd <checkout>/ArtStock
xcodegen generate --spec project.yml          # .xcodeproj 是产物，不入库
./scripts/mac-worker-build.sh ArtStock Release # 预检 + 出包 + JSON 汇报
# → build/ArtAssist-Release-<时间戳>.ipa （未签名）
```

或等价的完整 `make-unsigned-ipa.sh`。产物用 SideStore 装到 iPad（免费 Apple ID，
证书 7 天续签，同时最多 3 个自签 App）。
