# Palmos 架构

本文记录 Palmos 当前的系统边界、主要数据流和长期不变量。具体类型、调用关系和常量以当前源码与测试为准；产品能力和安装方式见 [README.md](../README.md)，开发与验证流程见 [development.md](development.md)。

## 系统定位

Palmos 是单用户、原生 macOS 菜单栏应用，以外接物理存储设备而不是挂载卷作为顶层对象。主应用无需特权即可完成设备发现、容量、吞吐、连接信息和整盘弹出。SMART 与部分占用诊断通过可选的特权 Helper 提供；Helper 未安装、版本不兼容或硬件不支持时，其他功能仍然可用，并以明确 capability state 降级。

部署目标是 macOS 26，发布架构仅为 arm64。App 使用 SwiftUI 和少量 AppKit bridge；系统集成依赖 DiskArbitration、IOKit、URL resource values、ServiceManagement 和 XPC。远程 Swift Package 为菜单栏窗口访问能力 `MenuBarExtraAccess` 与应用更新框架 Sparkle；`PalmosCore` 是仓库内本地 Swift Package。

## 运行时组件

```text
DiskArbitration / IOKit / URL resource values
                  │
                  ├── missing context: system_profiler JSON / diskutil plist
                  ▼
        App discovery and integration
                  │
                  ▼
          PalmosAppController (@MainActor)
          ├── PalmosCore models and reducers
          ├── throughput / capacity / SMART schedules
          ├── eject workflow
          └── SwiftUI state and views

Optional privileged path:
PalmosApp ── versioned XPC ──> PalmosSMARTService
                                  ├── trusted smartctl JSON
                                  └── bounded occupancy scan
```

`App/Application/PalmosApp.swift` 是 composition root。它创建共享的 `DeviceIOTracker`，将同一个 identity mapper 用于发现和 eject snapshot，组装 enrichment、SMART、吞吐与 eject 依赖，并将长期状态交给 `PalmosAppController`。协议与依赖注入隔离系统副作用，使 App 测试不依赖当前机器的存储设备或 Helper。

`PalmosAppController` 是主 actor 上的应用级协调器。它拥有发现观察、选中设备、增量 enrichment、容量刷新、吞吐采样、SMART 调度、Helper 状态和 eject UI 状态。SwiftUI View 只展示状态并发送用户意图，不直接枚举磁盘、启动子进程或调用 XPC。

## 设备发现、身份与拓扑

`LiveExternalDeviceDiscovery` 在专用 serial queue 上使用 IOKit/DiskArbitration 枚举媒体，并由 `DiskArbitrationDeviceMonitor` 监听磁盘出现、描述变化、消失和外部 eject intent。枚举记录经 `ExternalDeviceDiscoveryMapper` 转换为 `PalmosCore.ExternalDevice`。

发现层遵守以下语义：

- 顶层只包含外接物理设备；mounted volume、partition 和 APFS volume 是其子数据。
- internal、network、virtual media 和 iPhone/iPad 类挂载不进入设备列表。
- whole disk、APFS container、physical store 和 volume BSD name 是不同标识，不可混用。
- `DeviceIdentityResolver` 根据稳定证据组合建立身份；`DeviceIdentitySessionRegistry` 保留一次插入会话内的映射，拔出再插入形成新 session。
- 身份优先依赖 IORegistry entry 和唯一 media UUID，受证据约束的 BSD continuity 只用于同一 session；display name 和挂载路径不是身份。
- 冲突的同 BSD 记录及依赖它们的后代会被剔除，宁可缺失数据，也不猜测不明确拓扑。

初始快照先进入 UI，缺失的 APFS、连接和容量信息再异步补齐。Controller 使用 discovery generation、request generation 和任务取消，防止旧 enrichment 覆盖新设备或新一轮发现结果。

## 数据源与进程边界

数据源按以下优先级选择：

1. DiskArbitration、IOKit 和 URL resource values 等 Apple 原生 API。
2. 系统提供的结构化命令输出：`system_profiler` JSON、`diskutil` plist。
3. 明确的 unavailable、unsupported 或 error state。

`SystemProfilerProvider`、`DiskUtilAPFSProvider` 和 `VolumeCapacityRefresher` 只补充原生快照缺失的信息。它们通过 `DeviceIOTracker` 注册设备相关 I/O；eject 开始后 tracker 会阻止新操作，并让 `DeviceIOQuiescer` 等待已经开始的操作离开临界区。

App 子进程统一使用绝对 executable path 和参数数组。`SubprocessRunner` 提供取消、timeout、输出大小限制和非零退出处理。解析器与执行器分离，测试使用固定 JSON/plist fixture，不读取开发机当前硬件状态。

System Profiler 归属采用保守策略：NVMe 优先按 BSD name 精确匹配，缺失时仅接受唯一 model candidate；Thunderbolt 候选不唯一时不猜测归属。这些 enrichment 结果不是设备身份依据。

## 吞吐和会话指标

`IOKitDiskSampler` 读取物理设备累计读写计数；`ThroughputSamplingCoordinator` 管理采样生命周期；`ThroughputMetricsStore` 根据相邻计数计算速率并用 `PalmosCore.SessionMetricsReducer` 维护当前连接 session 的累计值与 bounded history。

采样以物理设备和拓扑映射为准。计数回退、设备更换或 session 更新会重建 baseline，不能把前一设备或前一插入会话的累计值带入当前 session。面板隐藏时继续累计，但不持续发布 UI；重新显示后再发布最新状态。

## SMART、Helper 与 XPC

`PalmosSMARTService` 是通过 ServiceManagement 安装的特权 LaunchDaemon。权限面限定为：

- 合约版本握手和 capability negotiation。
- 对通过校验的 whole-disk BSD name 执行 SMART 查询和取消。
- 安装经过 App/Helper 双重信任验证的 `smartctl` companion。
- 对经过验证的外接、可弹出 whole disk 进行有 deadline、数量和输出限制的占用扫描。

App 与 Helper 共同编译 `Shared/XPCContracts/`。`XPCContractVersion` 使用 major/minor 策略：major 不兼容会阻断调用，minor 能力通过 negotiation 单独启用。请求、响应、字符串、PID、BSD name、payload 大小和结果数量都在跨进程边界校验；新增方法或字段必须同步两端与兼容性测试。

Helper 只运行安装在 `/Library/PrivilegedHelperTools/com.palmos.smartservice.smartctl` 的可信 companion。安装和运行路径验证普通文件、root ownership、写权限、签名 identifier、Team ID 和固定摘要。`SmartctlRunner` 只接受 `diskN` whole-disk 名称，使用 JSON 输出、固定参数、timeout 和 stdout/stderr 上限；Helper 还限制全局及单设备 SMART 并发。

App 在 Helper 缺失、过旧、授权取消、XPC 失败、bridge 不透传 SMART 或需要未知 transport hint 时保留可用状态，并将具体原因映射为领域 capability，而不是崩溃或伪造 SMART 结果。

## 安全弹出与占用诊断

`EjectCoordinator` 为一次用户操作创建唯一 workflow ID，并通过 `EjectTargetResolver` 锁定 physical whole disk、IORegistry identity、当前拓扑和 mounted descendants。APFS synthesized container 只作为逻辑 unmount/topology target，不能成为顶层设备或最终物理 eject target。

磁盘拓扑变化后，协调器在关键阶段重新解析并比对目标；DiskArbitration sequence 在逻辑卸载、物理卸载和 eject 前也重新校验。无法证明仍是同一设备时停止操作，避免 BSD name 被复用后影响新插入设备。

正常流程固定为：

1. 关闭该设备的新 App-owned I/O，并等待进行中的 enrichment、容量或 SMART 操作退出。
2. 通过 DiskArbitration 正常卸载整个物理设备。
3. 对同一目标执行 eject。
4. 只有 eject 成功才进入“safe to remove”状态。
5. busy 时执行 App 侧与可选 Helper 侧占用诊断。
6. 只有用户在第二次确认中明确选择，才执行 force-unmount 后再次 eject。

force-unmount 成功但 eject 失败仍是失败。占用范围由 device node、精确 mounted descendants 和 APFS 拓扑构成，不能用路径前缀猜测。App/Helper 扫描均保持 deadline、取消、去重、结果上限和隐私边界；超时、权限或枚举不完整时不能把空结果解释为“无占用”。少数可正常 eject 但缺少 Helper 所要求 `ejectable` evidence 的设备，会将 root 占用诊断降级为不完整。

## UI、设置与更新

应用以 `MenuBarExtra` 的 window style 展示固定宽度面板。设置由 AppKit 管理 close-only preference window、原生 toolbar 和内容驱动的窗口尺寸，各 pane 仍由 SwiftUI 呈现；eject recovery window 也由专用 AppKit presenter 管理。界面状态来自 controller 或专用 presentation model，不复制发现、SMART 或 eject 的业务判断。

`AppSettings` 保存温度单位、面板可见性和 App 语言等轻量偏好，`LaunchAtLoginController` 管理登录启动。语言默认跟随系统，也可显式选择 English、Simplified Chinese 或 Traditional Chinese；切换后通过现有安全退出路径终止 App，再由生命周期监听启动新实例。用户可见字符串集中在 `App/Localization/Localizable.xcstrings`，至少维护上述三种 locale。

`ApplicationUpdateController` 封装 Sparkle。Debug 配置默认通过 `PALMOS_UPDATER_ENABLED = NO` 关闭更新能力，发布流水线显式配置频道。应用更新只替换 App，不隐式安装或升级 privileged Helper 或 companion；若能力不兼容，由 Helper 状态显式要求用户安装或升级。

## 构建与安全契约

- Swift 版本、部署目标、架构、bundle ID 和 Team ID 的配置入口在 `Config/xcconfigs/` 与对应 plist。
- App、Helper 和 companion 必须为 arm64，并使用同一 Team ID；App/Helper reciprocal signing requirements 不得弱化。
- Helper launchd plist、Info.plist section、embedded helper 路径、`SMAuthorizedClients` 和 `SMPrivilegedExecutables` 是一个耦合契约。
- `Config/Release/manifest.json` 是版本号和发布开关的唯一人工入口；生成的 `Config/Generated/Version.xcconfig` 将版本与更新频道提供给 App、Helper 和测试，CI 阻止两者漂移。release workflow 从通过 CI 的 main commit 构建签名 DMG。
- Palmos 源码使用 Apache License 2.0；MenuBarExtraAccess、Sparkle 和 smartmontools 的随包许可必须与实际分发内容同步。

## 稳定不变量

- 不把卷伪装成物理设备，也不让一次插入会话继承另一设备的身份或计数。
- 不让旧异步结果覆盖新发现、新选择或新 workflow。
- 不用 shell 拼接外部输入，不解析已有结构化替代方案的人类可读输出。
- 不把通用命令执行、任意路径访问或无界扫描放进 root Helper。
- 不在 eject 尚未成功时宣称设备可安全移除。
- 不因为 Helper 或 SMART 不可用而阻断非特权功能。
- 不让 Preview、fixture 或自动测试依赖真实外接盘、已安装 Helper 或用户数据。

## 硬件与环境限制

SMART 可用性取决于设备、桥接芯片和 transport passthrough，安装 Helper 不能改变硬件能力。占用扫描受 deadline、PID/holder 上限和系统权限限制，不是“无占用”的绝对证明。APFS container 的实时容量当前由其关联 mounted volume 的容量更新合并，不应描述为精确的共享 container 全局 accounting。

真实发现、吞吐、SMART、占用诊断和 eject 仍需在对应 USB、Thunderbolt/USB4、SD、APFS、多卷及未挂载设备上执行 [manual smoke checklist](../Scripts/verify/manual-smoke-checklist.md)；自动测试和无签名构建不能替代这些结果。
