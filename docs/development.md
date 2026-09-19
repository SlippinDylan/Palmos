# Palmos 开发与验证

本文记录 Palmos 的本地环境、构建测试、签名、CI、发布和开发产物清理流程。产品安装与使用见 [README.md](../README.md)，系统边界见 [architecture.md](architecture.md)。

## 环境与入口

- macOS 26 或更高版本，Apple Silicon。
- Xcode 26.4 和 macOS 26 SDK，与 CI 固定工具链一致。
- Swift 6；Core package 的最低平台同样是 macOS 26。
- Node.js，仅用于 GitHub 自动化和发布清单测试。
- 验证可安装 SMART Helper 时需要 Apple Development identity；免费 Personal Team 即可，不需要 Developer ID 或 notarization。

日常入口是 `Palmos.xcworkspace`，主 scheme 为 `PalmosApp`，Helper 安全测试 scheme 为 `PalmosSMARTServiceTests`。查看当前 workspace 配置：

```bash
xcodebuild -workspace Palmos.xcworkspace -list
```

Swift、deployment target、arm64 和签名基线在 `Config/xcconfigs/Base.xcconfig`；App/Helper 的 bundle 和 plist 设置分别在 `App.xcconfig`、`Helper.xcconfig` 与 `Config/Plists/`。不要把这些值散落复制到源码。

## 测试选择

按改动边界选择最小充分验证：

| 改动范围 | 必要验证 |
| --- | --- |
| 仅 `PalmosCore` 模型、parser、reducer | Core tests |
| App UI、状态、发现、metrics、integration | `PalmosApp` scheme tests；涉及 Core 时再跑 Core tests |
| Helper、XPC、SMART、占用扫描 | Core compatibility tests、App tests、`PalmosSMARTServiceTests` |
| 签名、plist、embedded Helper、companion、DMG | 上述测试、打包脚本测试、signed build、`code-signing.sh` |
| 真实设备发现、吞吐、SMART、eject | 自动测试后执行相关 manual smoke 项 |

### Core tests

```bash
cd Packages/PalmosCore
swift test
```

### App 与集成测试

```bash
xcodebuild test \
  -workspace Palmos.xcworkspace \
  -scheme PalmosApp \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY=""
```

### Helper 安全测试

```bash
xcodebuild test \
  -workspace Palmos.xcworkspace \
  -scheme PalmosSMARTServiceTests \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY=""
```

解析测试使用固定 JSON/plist fixture。不要让自动测试读取开发机当前存储拓扑、真实 App 数据、已安装 Helper 或管理员状态。

## 构建

常规 Debug 构建禁用签名：

```bash
xcodebuild build \
  -workspace Palmos.xcworkspace \
  -scheme PalmosApp \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY=""
```

与 CI 对齐的 unsigned Release 构建使用 generic macOS destination、显式 `ARCHS=arm64`、`ONLY_ACTIVE_ARCH=NO` 和独立 DerivedData。无签名 App 可验证大部分主应用行为，但不能证明 Helper 可安装、XPC 签名互信或 release packaging 正确。

## 本地 SMART 与签名

需要测试真实 Helper 安装和 SMART 路径时运行：

```bash
Scripts/build-local-smart-app.sh
```

脚本选择或接受一个 Apple Development identity，从固定摘要的 smartmontools 7.5 源码构建 arm64 companion，签名 App/Helper/companion，生成被 Git 忽略的 `Config/xcconfigs/Local.xcconfig`，并在结束前调用签名验证。存在多个 identity 时使用 `--identity SHA1`；可用环境变量和完整行为见 `--help`。

App、Helper 和 companion 必须使用同一 Team ID。改动以下任一部分时，要把它们作为整体核对：

- `SMAuthorizedClients` 与 `SMPrivilegedExecutables`。
- App/Helper runtime code-signing requirements。
- Helper launchd plist 与嵌入的 `__launchd_plist` section。
- App 内 embedded Helper/companion 路径与安装目标。
- companion identifier、root ownership、写权限和 SHA-256。

对已签名产物运行：

```bash
Scripts/verify/code-signing.sh /path/to/Palmos.app <TEAM_ID>
```

## 自动化检查

Ubuntu lightweight job 对所有变更执行 shell 语法、脚本自测、release manifest 校验和 Node 测试。可在本地运行：

```bash
bash -n Scripts/build-local-smart-app.sh
bash -n Scripts/build-smartctl-companion.sh
bash -n Scripts/create-dmg.sh
bash -n Scripts/verify/create-dmg-tests.sh
bash -n Scripts/verify/code-signing.sh
bash -n Scripts/verify/code-signing-tests.sh
bash -n Scripts/verify/local-smart-build-tests.sh
Scripts/build-local-smart-app.sh --help >/dev/null
node .github/scripts/release-manifest.mjs validate
node .github/scripts/sync-version.mjs --check
node --test .github/scripts/*.test.mjs
```

仓库没有 Makefile、SwiftLint、SwiftFormat 或独立架构 lint。不要创建虚假的统一 `lint`/`format` 工作流，也不要声称运行过不存在的命令。

## CI

`.github/workflows/test.yml` 在 main push、PR 和手工触发时运行：

1. Ubuntu lightweight check 分类变更并验证自动化。
2. 仅 README、LICENSE、AGENTS 和 `docs/*` 变化且 release 未开启时，可跳过 macOS job。
3. 其他变化或 `manifest.release == true` 时，在 `macos-26` runner 选择 Xcode 26.4。
4. macOS job 运行打包/签名脚本测试、构建 companion、Core tests、App tests、Helper tests 和 unsigned arm64 Release build。
5. 产物检查验证 arm64、macOS 26、rpath、Sparkle feed/public key 和 embedded framework。

本地验证范围应与改动风险匹配；不要把本地 unsigned build 成功等同于 signed Helper 或可发布 DMG 已验证。

## 手工验证

[Scripts/verify/manual-smoke-checklist.md](../Scripts/verify/manual-smoke-checklist.md) 是真实硬件和 release smoke 入口。发现、吞吐、容量、SMART、Helper 安装、外部进程占用和 eject 需要对应设备或管理员权限；没有执行时明确报告。

安全弹出 fixture 只用于没有价值数据的测试盘：

```bash
Scripts/verify/safe-eject-fixture.sh check --device diskN
```

脚本本身不会卸载或弹出设备。force path 仍必须由用户在 App 内二次确认，不能用 fixture 输出替代目标重验或数据安全判断。

UI 改动完成相关测试和构建后交由用户视觉验收。除非用户明确要求或提供截图，不主动启动 App、打开窗口或截图。

## 发布

`Config/Release/manifest.json` 是版本号和发布开关的唯一人工编辑入口：

```json
{
  "version": "x.y.z-beta.n",
  "release": false
}
```

版本支持 stable、alpha 和 beta。修改 manifest 后运行：

```bash
node .github/scripts/sync-version.mjs
```

该命令更新受版本控制的 `Config/Generated/Version.xcconfig`，供 App、Helper、测试及普通 Xcode Debug、Release 和 Archive 构建读取。预发布后缀不进入数字型 `MARKETING_VERSION`，而是生成对应的 `PALMOS_UPDATE_CHANNEL`；生成文件不得手工修改，CI 使用 `--check` 阻止它与 manifest 漂移。应用运行时只从 Bundle 读取版本信息，构建号仍由本地默认值或发布流水线的 GitHub run number 提供。

修改版本语义时同步检查 manifest validator、CHANGELOG、release workflow 和用户文档。

`.github/workflows/release.yml` 只接收 main 分支成功 CI 的 tested commit。release job 使用 Apple Development certificate，构建并签名 smartctl、App、Helper 和 Sparkle 嵌套组件，验证签名/架构/许可，生成 DMG 并发布 GitHub Release；随后由 distribution metadata workflow 更新对应 Homebrew Cask 和签名 appcast。当前分发不使用 paid Developer ID 或 notarization，不要局部改变这一模型。

Palmos 源码使用 Apache License 2.0。修改根 `LICENSE` 时同步 README、App bundle 许可证副本、固定摘要和打包测试。升级或改变随包依赖时核对：

- `Shared/Licensing/smartmontools-COPYING.txt` 及 smartmontools GPLv2-or-later 源码分发义务。
- `Shared/Licensing/MenuBarExtraAccess-LICENSE.txt`。
- Sparkle 的实际嵌入、签名和许可要求。

## 开发产物清理

只有用户明确要求清理时，才删除能够安全重新生成的内容。仓库内通常包括：

```text
.build/
Packages/**/.build/
DerivedData/
build/
Config/xcconfigs/Local.xcconfig
Config/xcconfigs/Local.xcconfig.tmp.*
```

删除前确认目标归属于当前仓库并统计空间；清理后报告主要目录与释放量。`/tmp`、`/private/tmp`、`/private/var/folders` 或仓库外 DerivedData 可能包含系统及其他项目数据，必须获得明确授权，并通过路径、项目名或构建元数据可靠归因于 Palmos。

不得删除源码、`.git/`、Xcode project/workspace、plist、xcconfig 基线、签名材料、用户设置、已安装 Helper、真实设备数据或用途不明的文件。

## 完成检查

每次交付至少完成：

```bash
git diff --check
git status --short
```

同时使用 `rg` 搜索新增/删除符号、用户可见字符串、bundle ID、contract version 和文档链接的所有引用。确认最终验证对应最终内容；验证后若继续修改代码，重新运行受影响的检查。报告实际执行的验证及未覆盖的真机、签名、管理员权限和多系统版本风险。
