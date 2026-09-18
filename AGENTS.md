# Palmos Agent 指南

本文件是仓库导航和工作契约，不是完整实现手册。只读取与当前任务相关的链接；源码、测试、工程配置和 CI 是实现事实来源。

## 项目概述

Palmos 是面向 macOS 26+、仅支持 Apple Silicon（arm64）的原生菜单栏 App。它以外接物理存储设备为顶层对象，展示吞吐、容量、卷/分区、连接链路和 SMART 健康，并提供整盘安全弹出。

应用使用 Swift 6、SwiftUI、DiskArbitration、IOKit、ServiceManagement/XPC。原生 API 无法覆盖的信息由受控的 `system_profiler`、`diskutil` 和 `smartctl` 补齐。产品说明见 [README.md](README.md)，当前架构见 [docs/architecture.md](docs/architecture.md)，开发与验证流程见 [docs/development.md](docs/development.md)。

## 开始工作

1. 检查 Git 状态，保留已有未提交改动，不清理或回退无关内容。
2. 阅读当前任务涉及的源码、测试和文档，确认既有职责、数据流与安全边界。
3. 搜索现有类型和调用点，沿用合理设计；只在当前需求需要时引入抽象或兼容层。
4. 修改公共契约、持久化结构、XPC、签名、Helper 安装或发布流程前，先说明影响；存在实质歧义时等待确认。

## 仓库地图

- `App/Application/`：依赖组装、`PalmosAppController` 和界面状态。
- `App/Integration/`：设备发现、系统数据源、子进程及 Helper/XPC 客户端。
- `App/Metrics/`：IOKit 采样和会话吞吐协调。
- `App/Eject/`：整盘弹出、I/O quiescence、目标重验与占用诊断。
- `App/UI/`、`App/Localization/`：SwiftUI 展示、设置和 String Catalog。
- `Packages/PalmosCore/`：无 AppKit、IOKit 和特权依赖的领域模型、解析器与 reducer。
- `Shared/XPCContracts/`：App/Helper 共同编译的版本化跨进程契约。
- `Shared/ProcessInspection/`：App/Helper 共用的进程检查边界。
- `Helper/`：SMART、可信 `smartctl` companion 和有界占用扫描。
- `Tests/`：App 集成/UI 模型、Helper 安全与打包测试。
- `Config/`、`Scripts/`、`.github/`：构建签名、验证、CI 和发布自动化。

新增或移动 Swift 文件时，必须同步检查 `Palmos.xcodeproj/project.pbxproj` 的 file reference、target membership 和 build phase。

## 不可破坏的边界

- 顶层对象始终是外接物理设备；卷是其子数据。排除 internal、network、虚拟媒体和 iPhone/iPad 挂载。
- 设备身份使用稳定证据组合并保留插拔 session 语义；不要用名称、挂载路径或枚举顺序代替身份。
- 区分 whole disk、APFS container、physical store 和 volume BSD name；跨层命名必须表达其语义。
- 数据源优先级是 Apple 原生 API、结构化命令输出、明确降级状态。`system_profiler` 使用 JSON，`diskutil` 使用 plist，`smartctl` 使用 JSON。
- 子进程使用绝对路径和参数数组，不经 shell 拼接；在边界校验输入，并处理退出码、stderr、空输出、取消、deadline 和大小上限。
- 设备相关 enrich、SMART 和 diskutil I/O 接入 `DeviceIOTracker`，确保 eject 能停止新操作并等待已有操作退出。
- `PalmosAppController` 负责状态和异步编排；View 不直接启动系统调用。UI 状态留在 `@MainActor`，长任务支持取消并防止 stale write。
- 跨任务值使用 `Sendable`；不要用 `@unchecked Sendable` 掩盖未说明的共享可变状态。
- Helper 只暴露版本握手、SMART、可信 companion 安装和经过验证的有界占用扫描；禁止加入通用 root 命令执行能力。
- 修改 XPC schema 或 selector 时保持 major/minor 兼容策略，并同步 App、Helper、capability negotiation 和兼容性测试。
- 不得削弱 App/Helper 双向 code-signing requirement、相同 Team ID、`SMAuthorizedClients` 或 `SMPrivilegedExecutables`。
- eject 顺序保持：quiesce App-owned I/O → normal whole-disk unmount → eject → busy diagnostics → 用户二次确认后的 force path。只有 eject 成功才能报告可安全移除。
- eject workflow 必须锁定并重验同一物理目标，防止 BSD name 重用；占用扫描保持精确拓扑、结果上限、deadline、取消和隐私边界。
- macOS 26 是 deployment target；采用更高系统版本 API 时必须保留 macOS 26 路径。
- 用户可见字符串进入 `App/Localization/Localizable.xcstrings`，至少检查 English、Simplified Chinese 和 Traditional Chinese。

## 常用命令

从仓库根目录执行；验证矩阵、签名和发布流程见 [docs/development.md](docs/development.md)。日常 CI 验证禁用签名，验证 Helper 安装或打包时必须保留签名。

```bash
(cd Packages/PalmosCore && swift test)
xcodebuild test -workspace Palmos.xcworkspace -scheme PalmosApp -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
xcodebuild test -workspace Palmos.xcworkspace -scheme PalmosSMARTServiceTests -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
xcodebuild build -workspace Palmos.xcworkspace -scheme PalmosApp -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
```

仓库没有 Makefile、SwiftLint、SwiftFormat 或统一架构 lint 命令，不要声称已运行不存在的检查。

## 验证与完成标准

- 先运行覆盖改动的最小测试；跨越 Core、App、Helper、XPC 或签名边界时扩大到所有受影响 target。
- 解析器用固定 fixture 验证，不依赖开发机硬件输出；真实发现、SMART 和 eject 行为按手工 checklist 在合适硬件上验证。
- Helper、签名或打包改动同时检查 App、Helper、companion、嵌入路径、launchd plist 和 reciprocal signing requirements。
- UI 修改不主动启动 App 或截图；用户提供截图或明确要求视觉验证时再执行。
- 完成前运行 `git diff --check`，搜索新旧符号及契约引用，并检查 diff 中没有调试输出、临时文件或无关修改。
- 未验证的真机、管理员权限、签名、Helper 安装或多 macOS 版本场景必须明确报告。

## 文档、清理与 Git

- README 记录用户可见能力与安装方式；架构和开发流程分别维护在对应文档。源码能清晰表达的成员列表不复制进文档。
- 新增和维护的项目内部文档使用中文；代码注释使用英文，只解释原因、约束和非显而易见的决策。
- 只有用户明确要求时才清理可安全重建的产物。仓库外临时目录必须能可靠归属于 Palmos；不得删除源码、Git 数据、配置、用户数据或用途不明的文件。
- 未经明确要求，不提交、推送、重写历史、创建 Release，或修改与任务无关的 Git 状态。
- 根 `AGENTS.md` 保持为高价值入口；详细知识放 `docs/`，重复流程放 Skill 或脚本，强约束优先由类型、测试和 CI 固化。

## 文档导航与权威顺序

- [docs/architecture.md](docs/architecture.md)：系统组件、数据流、安全边界和稳定不变量。
- [docs/development.md](docs/development.md)：环境、构建、测试、签名、CI、发布和清理。
- [Scripts/verify/manual-smoke-checklist.md](Scripts/verify/manual-smoke-checklist.md)：真机与 release smoke checklist。
- [Shared/XPCContracts/PalmosXPCContracts.swift](Shared/XPCContracts/PalmosXPCContracts.swift)：XPC 版本与协议入口。
- [Config/Release/manifest.json](Config/Release/manifest.json)：发布候选版本与显式发布开关。

信息冲突时按当前工程配置/源码/测试/CI → 当前架构与开发文档 → README/manual checklist → 历史设计记录判断。冲突影响需求、公共契约或安全边界时，不自行选择，说明事实和影响后等待确认。`docs/superpowers/` 若本地存在，只作为可能过期的历史记录。
