# AGENTS.md

## 1. 项目定位

Palmos 是面向 macOS 15+ 的菜单栏 App，以外接物理存储设备为顶层对象，展示实时读写、容量、卷/分区、连接链路与 SMART 健康信息。代码使用 Swift 6、SwiftUI、DiskArbitration、IOKit、ServiceManagement/XPC；原生 API 无法覆盖的数据由受控的 `system_profiler`、`diskutil`、`smartctl` 子进程补齐。为与 CI 一致，使用 Xcode 26.4/macOS 26 SDK；macOS 26 API 即使有 availability guard，也需要对应 SDK 才能编译。

本文件是 Agent 的项目导航与硬约束。产品说明、安装/签名方式和常用命令见 [README.md](README.md)；实现细节以当前源码和测试为准。

## 2. 快速命令

从仓库根目录执行。日常 CI 验证禁用签名；涉及 Helper 安装、签名或打包时必须保留签名并使用 App/Helper 相同 Team ID。

```sh
# 查看 workspace、scheme 与 target
xcodebuild -workspace Palmos.xcworkspace -list

# Core 单元测试（与 CI 一致）
cd Packages/PalmosCore && swift test

# App 与集成测试
xcodebuild test \
  -workspace Palmos.xcworkspace \
  -scheme PalmosApp \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""

# Privileged Helper 安全测试
xcodebuild test \
  -workspace Palmos.xcworkspace \
  -scheme PalmosSMARTServiceTests \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""

# Debug build
xcodebuild build \
  -workspace Palmos.xcworkspace \
  -scheme PalmosApp \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
```

手工验证入口：

- [Scripts/verify/manual-smoke-checklist.md](Scripts/verify/manual-smoke-checklist.md)：重大 App/Helper 改动与发布前检查。
- [Scripts/verify/code-signing.sh](Scripts/verify/code-signing.sh)：验证 App、内嵌 Helper、Team ID 和双向 signing requirements。
- [Scripts/verify/safe-eject-fixture.sh](Scripts/verify/safe-eject-fixture.sh)：仅用于无价值数据的外接测试盘；脚本不会主动卸载或弹出磁盘。

仓库当前没有 Makefile、SwiftLint、SwiftFormat 或架构 lint 配置；不要凭空添加或声称存在统一 `lint`/`format` 命令。

## 3. 仓库地图

```text
Palmos/
├── Apps/
│   ├── PalmosApp/                  # 菜单栏 App
│   │   ├── App/                        # composition root、控制器、界面状态
│   │   ├── Integration/                # 系统 API、子进程、Helper/XPC 客户端
│   │   ├── Metrics/                    # IOKit 实时磁盘采样
│   │   ├── Eject/                      # 安全弹出、占用诊断、I/O quiescence
│   │   ├── UI/                         # SwiftUI 视图与展示模型
│   │   ├── Localization/               # String Catalog
│   │   └── Resources/                  # App 图标等资源
│   ├── PalmosAppTests/             # App、集成层、UI 模型与打包测试
│   ├── PalmosSMARTService/         # root Helper、smartctl、占用扫描
│   └── PalmosSMARTServiceTests/    # Helper 输入边界与安全测试
├── Packages/PalmosCore/            # 无 AppKit/IOKit/特权依赖的共享逻辑
│   ├── Sources/PalmosCore/
│   │   ├── Domain/                     # 设备、卷、SMART、链路领域模型
│   │   ├── Discovery/                  # 身份解析与设备列表 reducer
│   │   ├── Metrics/                    # 会话吞吐 reducer
│   │   ├── SMART/                      # smartctl JSON 解析与温度选择
│   │   └── Settings/                   # 可持久化用户设置
│   └── Tests/PalmosCoreTests/
├── Shared/XPCContracts/                # App/Helper 共同编译的版本化 XPC 合约
├── Shared/Licensing/                   # bundled third-party licenses
├── Config/xcconfigs/                   # Swift、部署版本、签名、bundle ID
├── Config/Plists/                      # App/Helper Info.plist 与 SMJobBless 约束
├── Scripts/verify/                     # 签名与真机 smoke 验证
├── Palmos.xcworkspace              # 日常构建入口
└── .github/workflows/                  # PR 测试与 main 分支 release
```

新增或移动 Swift 文件时，必须同步检查 `Palmos.xcodeproj/project.pbxproj` 的 file reference、target membership 与 build phase；仅在磁盘上创建文件不代表 Xcode target 会编译它。

## 4. 架构与数据流

```text
DiskArbitration / IOKit / NSURL resourceValues
                  │
                  ├── 缺失信息：system_profiler / diskutil
                  ▼
        PalmosApp Integration
                  │
                  ▼
          PalmosAppController
          ├── PalmosCore reducers/models
          └── SwiftUI state and views

Optional SMART / privileged occupancy path:
PalmosApp ── versioned XPC ──> PalmosSMARTService ──> smartctl / bounded root scan
```

- `PalmosApp.swift` 是依赖组装入口；协议与依赖注入用于隔离系统副作用并支持测试。
- `PalmosAppController` 统一协调发现、增量 enrich、吞吐采样、SMART、容量刷新与 eject；不要让 View 直接启动系统调用。
- `PalmosCore` 保存可复用领域模型和纯逻辑。能在无 UI、无 root、无机器环境下测试的逻辑优先放这里。
- `Shared/XPCContracts` 是跨进程 ABI/协议边界，不是普通 DTO 目录；两端与兼容性测试必须一起修改。
- `PalmosSMARTService` 只承载确实需要特权的能力。App 在未安装 Helper 时仍必须可用，SMART 以明确 capability state 降级。

## 5. 不可破坏的项目约束

### 5.1 设备与拓扑

- 顶层选择单位始终是外接物理设备，mounted volume 是其子数据；禁止把单个卷伪装成物理设备。
- 排除 internal、network、iPhone/iPad 类设备；修改发现规则时覆盖 USB、Thunderbolt/USB4、SD、未挂载设备和多卷/APFS 场景。
- 设备身份必须使用稳定证据组合并保留插拔 session 语义；不要仅凭 display name、mount path 或瞬时枚举顺序做身份。
- APFS container、physical store、whole disk、volume BSD name 含义不同；跨层传递时命名必须标明语义。

### 5.2 数据源与子进程

- 数据源优先级：Apple 原生 API → 结构化命令输出 → 明确降级状态。不要用 CLI 替代已有可靠原生路径。
- `system_profiler` 使用 JSON，`diskutil` 使用 plist，`smartctl` 使用 JSON；禁止依赖面向人的格式化文本，除非系统没有结构化输出且附带 fixture 测试。
- 子进程必须使用绝对 executable path 与参数数组，不经 shell 拼接；校验 BSD name 等外部输入，并显式处理退出码、stderr、空输出、取消和大小上限。
- 针对某个设备的 App-owned enrich/SMART/diskutil I/O 必须接入 `DeviceIOTracker`，使 eject 前能停止新操作并等待进行中的操作退出。
- 解析逻辑与进程执行分离；解析器使用固定 fixture/JSON/plist 测试，不依赖开发机当前硬件输出。

### 5.3 Helper、XPC 与签名安全

- Helper 权限面保持最小：只暴露版本握手、SMART 读取和经过验证且有界的占用扫描；不要把通用 root 命令执行能力放进 XPC。
- XPC request/response 必须 Codable、可验证、有大小/数量边界；来自客户端的 BSD name、PID、字符串和 schema version 都是不可信输入。
- 修改 `XPCContractVersion` 或方法时，保留 major/minor 兼容策略：major 不兼容应阻断，minor 能力通过 capability negotiation 降级；同步更新 App、Helper 与兼容性测试。
- 不得削弱 `SMAuthorizedClients`、`SMPrivilegedExecutables`、运行时 code-signing requirement 或 App/Helper 相同 Team ID 的约束。
- Helper 安装/移除、launchd plist、Info.plist section、embedded helper 路径互相耦合；改任一项时必须运行打包测试和签名脚本。

### 5.4 安全弹出

- eject workflow 必须锁定并在关键阶段重新验证同一个 whole-disk target，防止 BSD name 被重用后作用于新设备。
- 顺序保持：quiesce Palmos-owned I/O → normal whole-disk unmount → eject → busy diagnostics → 用户明确确认后的 force path。
- 未完成 eject 不得展示“safe to remove”；force-unmount 成功但 eject 失败仍是失败状态。
- force eject 是破坏性操作，必须二次确认，安全/取消操作保持默认优先。
- 占用扫描必须精确匹配 device node、mount descendants 与 APFS 拓扑，保持结果上限、deadline、取消与隐私边界。

### 5.5 Swift、并发与 UI

- 以 Swift 6 concurrency checking 为准：UI/state mutation 留在 `@MainActor`；跨任务值使用 `Sendable`；不要用 `@unchecked Sendable` 掩盖未说明的共享可变状态。
- 长任务必须支持 cancellation，并用 generation/workflow ID 防止过期结果覆盖新插入设备或新请求。
- 错误必须转换为明确的领域/capability state 或 `LocalizedError`；禁止吞异常、返回含义不明的 `nil`、仅写日志后假装成功。
- macOS 15 是 deployment target；macOS 26 专属 API 必须以 `#available`/`@available` 守卫并保留 macOS 15 路径。
- 保持原生 SwiftUI 菜单栏体验，不引入重型 UI 依赖；当前唯一远程 Swift Package 是 `MenuBarExtraAccess`，不要无理由扩展依赖面。
- 用户可见字符串进入 `Apps/PalmosApp/Localization/Localizable.xcstrings`；至少检查 English、Simplified Chinese、Traditional Chinese，并更新相关 catalog/UI 测试。

## 6. 修改路由

| 需求 | 首选位置 | 同步检查 |
| --- | --- | --- |
| 领域模型、SMART parser、吞吐 reducer | `Packages/PalmosCore/Sources/PalmosCore/` | Core tests；public API 的 App 调用点 |
| 设备发现、容量、APFS/链路 enrich | `Apps/PalmosApp/Integration/` | mapper/controller tests；设备 identity 与 stale-write 防护 |
| 菜单栏状态协调 | `Apps/PalmosApp/App/` | `PalmosAppControllerTests.swift`；MainActor/cancellation |
| SwiftUI 布局与展示 | `Apps/PalmosApp/UI/` | 360 pt 面板、空/错误/加载状态、三种语言 |
| 安全弹出与占用诊断 | `Apps/PalmosApp/Eject/` | eject unit/integration tests；manual disposable-media checklist |
| SMART/Helper 客户端 | `Integration/SMARTServiceClient.swift`、`SMARTHelperManager.swift` | XPC compatibility、取消、helper absent/outdated states |
| XPC schema/capability | `Shared/XPCContracts/` | App + Helper + Core compatibility tests |
| root-side 实现 | `Apps/PalmosSMARTService/` | 输入验证、deadline/limit、Helper security tests |
| bundle、签名、Helper packaging | `Config/`、project file、verify scripts | `Task7HelperPackagingTests`、signed build、code-signing script |

## 7. 验证矩阵

按改动范围运行最小充分集合；跨边界改动扩大到所有受影响 target。

- 仅 `PalmosCore`：`swift test`。
- App UI/state/integration：`PalmosApp` scheme tests；涉及 Core 时再跑 Core tests。
- Helper/XPC/签名：Core compatibility tests + App tests + `PalmosSMARTServiceTests`；PR CI 会运行 Helper scheme，本地仍需在交付前确认退出码为 0；打包改动再做 signed build 与 `code-signing.sh`。
- 发现、吞吐、SMART、eject 的真实硬件行为：自动测试后执行相关 manual smoke 项；不要声称已验证未连接的硬件或未安装的 Helper。
- 发布相关：对照 `.github/workflows/test.yml` 和 `.github/workflows/release.yml`，不要把本地无签名成功等同于可安装 Helper 的 release 成功。

每次交付前至少完成：

1. `git diff --check`。
2. `rg` 检查新旧符号、字符串、bundle ID 或 contract version 的所有引用。
3. 运行上面的相关测试并确认实际退出码为 0。
4. 检查无未使用 import、调试输出、临时 fixture 或意外 project file 变更。
5. 明确报告未能在当前机器验证的真机、签名、管理员权限或多 macOS 版本场景。

## 8. 构建、签名与发布约束

- 配置源在 `Config/xcconfigs/`；Swift 6、macOS 15 deployment target、bundle IDs 和 Team ID 不应散落复制到源码。
- Fork 使用者可替换 `Base.xcconfig` 的 `DEVELOPMENT_TEAM`，但 App 与 Helper 必须继承同一 Team ID。
- PR CI 使用 macOS 26 runner 与固定 Xcode，命令行禁用签名；修改 SDK/API 使用后同时确认本地与 CI Xcode 能力。
- release 使用免费 Apple Development 证书，不依赖 paid Developer ID/notarization；不要擅自改成要求付费签名的分发模型。
- `MARKETING_VERSION` 是 release tag 的版本来源；版本与 release workflow 的更改必须保持单一来源。
- `Shared/Licensing/smartmontools-COPYING.txt` 与 `MenuBarExtraAccess-LICENSE.txt` 不得随意删除；任何分发 `smartctl` 的方案都必须同步核对 GPLv2 许可义务，升级 SwiftPM 依赖时必须同步核对并测试随包分发的许可声明。

## 9. 文档导航

| 文档/位置 | 用途 |
| --- | --- |
| [README.md](README.md) | 产品范围、支持设备、安装、Helper、构建、签名与发布说明 |
| [Packages/PalmosCore/Package.swift](Packages/PalmosCore/Package.swift) | Core 平台、product 和 test target 定义 |
| [Config/xcconfigs/Base.xcconfig](Config/xcconfigs/Base.xcconfig) | Swift、deployment target、签名基线 |
| [Shared/XPCContracts/PalmosXPCContracts.swift](Shared/XPCContracts/PalmosXPCContracts.swift) | XPC 版本与协议入口 |
| [Scripts/verify/manual-smoke-checklist.md](Scripts/verify/manual-smoke-checklist.md) | 真机与 release smoke checklist |
| [.github/workflows/test.yml](.github/workflows/test.yml) | PR CI 的权威测试环境和命令 |
| [.github/workflows/release.yml](.github/workflows/release.yml) | 构建、签名、校验、打包与 GitHub Release 流程 |

权威顺序：当前工程配置/源码/测试/CI → 本文件 → README 与 manual checklist → 历史设计记录。发现冲突时先验证现状并修正文档，不要照搬旧描述。

`docs/superpowers/` 若在本地存在，只作为历史设计/实施记录；它被 `.gitignore` 忽略，可能过期或不随 clone 分发，不能替代当前源码、测试、README 和本文件。
