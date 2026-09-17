<div align="center">
  <img src="images/readme/app-icon.png" width="160" height="160" alt="Palmos 应用图标">
  <h1>Palmos</h1>
  <p>一款原生 macOS 菜单栏应用，用来监控外接物理存储设备。</p>
  <p>
    <strong>简体中文</strong> ·
    <a href="README.zh-TW.md">繁體中文</a> ·
    <a href="../README.md">English</a> ·
    <a href="README.ja.md">日本語</a> ·
    <a href="README.ru.md">Русский</a>
  </p>
</div>

## Palmos 是什么

Palmos 把外接硬盘的状态放进菜单栏。打开原生面板即可查看容量、已挂载卷、连接链路、实时读写、安全弹出，以及可选的 SMART 健康和温度数据。

顶层对象始终是外接物理设备，卷和分区显示在设备下面。Palmos 不显示内置存储、网络卷、虚拟磁盘，以及 iPhone 或 iPad 挂载。

## 功能

<table>
  <tr>
    <td width="32%">
      <strong>常驻菜单栏</strong><br><br>
      自动发现 USB、Thunderbolt、USB4、SD、外接 SSD、HDD 和 NVMe 硬盘盒，需要时打开一个紧凑的原生面板。
    </td>
    <td width="68%" align="center"><img src="images/readme/menu-panel.png" width="406" alt="显示概览、吞吐、容量、SMART 和温度数据的 Palmos 菜单栏面板"></td>
  </tr>
  <tr>
    <td>
      <strong>可选 SMART 监控</strong><br><br>
      需要更广的 SMART 健康和温度覆盖时，再安装权限范围受控的 Helper。未安装 Helper 时，其他功能仍然可用。
    </td>
    <td align="center"><img src="images/readme/smart-helper-settings.png" width="520" alt="显示 SMART Helper 已安装的 Palmos 设置"></td>
  </tr>
</table>

## 支持范围

| 项目 | 内容 |
|---|---|
| 支持设备 | USB 存储、Thunderbolt / USB4 存储、SD 卡、外接 SSD 和 HDD、外接 NVMe 硬盘盒 |
| 排除设备 | 内置存储、网络卷、虚拟磁盘、iPhone 和 iPad 挂载 |
| 顶层模型 | 外接物理设备，已挂载卷显示在设备下面 |
| 最低系统 | macOS 26 或更高版本 |
| 架构 | Apple 芯片（arm64） |
| 构建环境 | Xcode 26.4 或更高版本，并安装 macOS 26 SDK |
| 分发方式 | GitHub Releases 提供 Apple Development 签名、未经公证的 DMG |

## 安装与发布

每个 GitHub Release 只包含一个 arm64 制品 `Palmos-v<版本号>.dmg`。打开 DMG，把 `Palmos.app` 拖入 `Applications`。Release 使用免费的 Apple Development 证书，使 App、特权 Helper 和随包提供的 `smartctl` companion 能够互相验证。当前 Release 未经过 Apple 公证，第一次打开前需要移除下载隔离属性：

```bash
sudo xattr -rd com.apple.quarantine /Applications/Palmos.app
```

移除隔离属性不能代替代码签名验证。正常打开 Palmos，只在需要 SMART 时从设置中安装 Helper。

发布配置位于 [`Config/Release/manifest.json`](../Config/Release/manifest.json)。只有 main CI 成功、`release` 为 `true`、版本尚未发布，并且 [CHANGELOG.md](../CHANGELOG.md) 存在唯一、非空且完全同名的版本章节时，Release workflow 才会签名、打包和发布。版本支持 `x.y.z`、`x.y.z-alpha.n` 和 `x.y.z-beta.n`。

发布自动化使用以下 GitHub Actions repository secrets：

- `CERTIFICATES_P12`：Apple Development P12 的 Base64 内容
- `CERTIFICATES_PASSWORD`：P12 导出密码
- `FEISHU_WEBHOOK`：飞书自定义机器人 Webhook
- `FEISHU_SECRET`：飞书自定义机器人签名密钥

旧的证书 secret 名 `APPLE_DEVELOPMENT_P12_BASE64` 和 `APPLE_DEVELOPMENT_P12_PASSWORD` 仍然兼容。

- `SPARKLE_ED_PRIVATE_KEY`：Sparkle EdDSA 更新签名私钥
- `HOMEBREW_TAP_TOKEN`：仅对 `SlippinDylan/homebrew-tap` 有 Contents 写权限的细粒度 Token

### Homebrew

接入 Sparkle 的 GitHub Release 公开后，共享 Tap 会发布固定版本 DMG checksum 和已签名 appcast：

```bash
brew tap slippindylan/tap
brew trust --tap slippindylan/tap
brew install --cask palmos@beta
```

稳定版使用 `palmos`，alpha 使用 `palmos@alpha`；每个 Cask 都固定指向对应 GitHub Release 的 DMG。

### App 更新

Palmos 使用 Sparkle 2 自动后台检查更新，也可在“设置 → 关于”选择“检查更新…”。它会校验 EdDSA 签名的更新包和公开 appcast：`https://slippindylan.github.io/homebrew-tap/palmos/appcast.xml`。稳定、beta、alpha 共用一个 feed，但只接收各自允许的渠道。

App 更新只替换 `Palmos.app`，不会安装或升级特权 SMART Helper 及其签名的 `smartctl` companion。Helper 需要更新时，仍应在“设置 → SMART Helper”中显式操作并通过 macOS 管理员授权。

## 特权 SMART Helper

可选 Helper 通过 `SMJobBless` 安装到 `/Library/PrivilegedHelperTools/com.palmos.smartservice`。它只提供版本协商、有界 SMART 读取、companion 安装和有界占用诊断。Companion 安装到 `/Library/PrivilegedHelperTools/com.palmos.smartservice.smartctl`；Palmos 不会从 Homebrew 或其他用户可写路径加载 `smartctl`。

每次 SMART 操作前都会检查 XPC 兼容性：

- 主版本不一致会阻止操作并要求更新。
- 次版本不一致会降级到两端共同支持的能力。

删除 App 不会自动删除 Helper。请在删除 Palmos 前后手动执行：

```bash
sudo launchctl bootout system /Library/LaunchDaemons/com.palmos.smartservice.plist
sudo rm /Library/LaunchDaemons/com.palmos.smartservice.plist
sudo rm /Library/PrivilegedHelperTools/com.palmos.smartservice
sudo rm /Library/PrivilegedHelperTools/com.palmos.smartservice.smartctl
```

## 从源码构建

打开 `Palmos.xcworkspace`，选择 `PalmosApp` scheme 后构建。未签名版本可以在不使用 SMART 的情况下运行；SMART 路径要求 App、Helper 和 companion 使用同一个 Apple Development Team。

创建 Apple Development 签名身份后，运行：

```bash
Scripts/build-local-smart-app.sh
```

脚本会从固定且经过 checksum 验证的源码重新构建 smartctl 7.5，签名后把 SHA-256 传给 Helper，再使用从签名中提取的 Team ID 构建全部组件并执行完整签名检查。脚本不会自动清理其他 Team 已安装的 Helper。

## 测试

```bash
cd Packages/PalmosCore && swift test

xcodebuild test \
  -workspace Palmos.xcworkspace \
  -scheme PalmosApp \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
```

main push 和 Pull Request 始终运行轻量发布自动化检查。仅修改 `README.md`、`docs/`、`LICENSE` 或 `AGENTS.md` 时跳过 macOS 构建，但启用发布时仍会强制执行完整检查。其他变更会运行 Core、App、Helper 安全、打包和未签名 arm64 构建检查。

## 许可证

Copyright © 2025–2026 SlippinDylan Studio。Palmos 使用 [Apache License 2.0](../LICENSE) 开源许可证。

### 第三方许可证

Palmos 随包提供按 MIT License 发布的 [MenuBarExtraAccess 1.3.0](https://github.com/orchetect/MenuBarExtraAccess)，以及由 smartmontools 7.5 构建、按 GPL version 2 or later 发布并单独签名的 `smartctl`。完整声明位于 [`Shared/Licensing`](../Shared/Licensing)，也会包含在 App 中。

对应的 smartmontools 源码归档内嵌在 `Palmos.app/Contents/Resources/ThirdPartySources/smartmontools-7.5.tar.gz`，要求的 SHA-256 为 `690b83ca331378da9ea0d9d61008c4b22dde391387b9bbad7f29387f2595f76e`。
