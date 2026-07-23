# Palmos

**简体中文** | [繁體中文](README.zh-Hant.md) | [English](README.en.md)

Palmos 是一款 macOS 菜单栏 App，用来监控已连接的外接物理存储设备。它会在原生菜单栏窗口中显示设备健康状态、连接信息、容量、已挂载卷和实时读写速度。

## 系统要求

- macOS 15 或更高版本
- Xcode 26.4 或更高版本，并安装 macOS 26 SDK（从源码构建时需要）

## 支持的设备

- USB 存储设备
- Thunderbolt / USB4 存储设备
- SD 卡存储设备
- 外接 SSD 和 HDD
- 外接 NVMe 硬盘盒

Palmos 不会显示网络卷、内置存储设备，以及以类似方式挂载的 iPhone / iPad。

## 架构

Palmos 包含三个 target：

- **PalmosApp**：菜单栏 App、界面、设备浏览、吞吐图表、设置、登录时启动和安全弹出。
- **PalmosCore**：共享的领域模型与应用逻辑，不依赖 UI 或特权能力。
- **PalmosSMARTService**：通过 `SMJobBless` 安装、经 XPC 调用的特权 Helper。它只处理 SMART 相关操作，并负责安装由 Palmos 签名的 `smartctl` companion。

没有安装特权 Helper 时，App 的其他功能仍可正常使用。SMART 是分层提供、由用户选择启用的能力。

## 安装 GitHub Release

Palmos Release 使用免费的 Apple Development 证书，让 App 和特权 Helper 能够相互验证。Release 未经过 Apple 公证，因此将 `PalmosApp.app` 移到 `/Applications` 后，需要执行一次以下命令来移除下载隔离属性：

```sh
sudo xattr -rd com.apple.quarantine /Applications/PalmosApp.app
```

这个递归命令也会处理 App 包内嵌的 Helper。不要把 Helper 单独复制出来，也不需要再对它执行一次 `xattr`。正常打开 Palmos，需要时再到设置中安装 SMART Helper。

移除隔离属性只会跳过 Gatekeeper 对下载文件的隔离检查，不能取代代码签名。Release workflow 会使用同一个 Apple Development Team 签名 App 和 Helper。

## 特权 SMART Helper

首次请求高级 SMART 监控时，Palmos 会安装特权 Helper。Apple 的 App 沙盒 API 无法读取大多数外接硬盘盒的 SMART 遥测数据，因此要覆盖更多 Thunderbolt 和 USB 硬盘盒，需要使用这个 Helper。

Helper 安装在 `/Library/PrivilegedHelperTools/com.palmos.smartservice`，并注册为 launchd daemon。安装时系统会要求输入管理员凭据。Helper 验证固定的代码签名标识符和一致的 Team ID 后，同一流程才会把随包提供的 companion 安装到 `/Library/PrivilegedHelperTools/com.palmos.smartservice.smartctl`。安装后的文件归 root 所有，Palmos 不会从 Homebrew 或其他用户可写的命令路径加载它。

### Helper 版本兼容

每次执行 SMART 操作前，App 都会检查 XPC contract 的兼容性：

- **主版本不一致**：阻止 SMART 操作，并要求更新。
- **次版本不一致**：降级运行；共享 contract 支持的 SMART 功能仍然可用。

### 移除 Helper

删除 App 本身**不会**自动移除特权 Helper。当前版本还没有提供卸载按钮，请在删除 Palmos 前后手动执行：

```sh
sudo launchctl bootout system /Library/LaunchDaemons/com.palmos.smartservice.plist
sudo rm /Library/LaunchDaemons/com.palmos.smartservice.plist
sudo rm /Library/PrivilegedHelperTools/com.palmos.smartservice
sudo rm /Library/PrivilegedHelperTools/com.palmos.smartservice.smartctl
```

## 从源码构建

在 Xcode 中打开 `Palmos.xcworkspace`，选择 `PalmosApp` scheme 后构建。
未签名版本可以在不使用 SMART 的情况下运行；特权 SMART 路径要求稳定的代码签名身份，以便 App、Helper 和 `smartctl` companion 相互验证。

`PalmosSMARTService` scheme 用来构建特权 Helper。仓库默认使用维护者公开的 Team ID。免费 Personal Team 用户可以在 Xcode 的 **Settings → Accounts → Manage Certificates** 中创建 Apple Development 证书。本地使用不需要付费加入 Apple Developer Program，也不需要 Developer ID 证书或 Apple 公证。

Pull Request 测试会在命令行中明确禁用签名，本地编译和测试也可以这样做。凡是需要运行 SMART Helper 的构建，都必须用同一个免费 Apple Development Team 签名 App、Helper 和 companion。

普通 Debug 构建不会下载第三方工具。创建 Apple Development 证书后，可以用专用脚本构建支持 SMART 的本地 App：

```sh
Scripts/build-local-smart-app.sh
```

如果机器上有多个 Apple Development 签名身份，先用以下命令列出 SHA-1：

```sh
security find-identity -v -p codesigning
```

再明确选择其中一个：

```sh
Scripts/build-local-smart-app.sh --identity APPLE_DEVELOPMENT_SHA1
```

脚本每次都会在隔离目录中，从固定版本且经过 SHA 校验的源码归档重新构建 smartctl。它会签名新生成的二进制，将签名后的 SHA-256 传给 Helper，再使用从 companion 签名中提取的 Team ID 构建全部组件并执行完整签名检查。验证通过的 companion 会放到 `DerivedData/LocalSMART` 下不可变的摘要命名路径；只有所有检查都通过后，脚本才会原子替换被 Git 忽略的 `Config/xcconfigs/Local.xcconfig`。之后从 Xcode 执行 **Cmd+R** 会复用这个已经验证的 companion 和 Personal Team；命令行显式禁用签名时则不会嵌入它。脚本最后会输出可以启动的 `.app` 完整路径。

如果所选 Personal Team 与已安装 Helper 的 Team ID 不一致，请先按照[移除 Helper](#移除-helper)中的命令清理旧版本，再从新构建安装。已安装的 Helper 只授权原 Team 的客户端，本地构建脚本不会自动执行破坏性的系统清理。

Release workflow 会在 CI 中执行等价流程。如果 companion、签名、许可证或源码归档缺失，构建会直接失败。

### GitHub Release 签名

Release workflow 需要配置两个 GitHub Actions secret：

- `APPLE_DEVELOPMENT_P12_BASE64`：导出的 Apple Development 证书及私钥，以 base64 编码。
- `APPLE_DEVELOPMENT_P12_PASSWORD`：P12 文件的导出密码。

例如，将证书导出为 `AppleDevelopment.p12` 后，可以用以下命令复制编码内容：

```sh
base64 -i AppleDevelopment.p12 | pbcopy
```

在仓库的 **Settings → Secrets and variables → Actions** 中添加编码内容和导出密码。Workflow 会从证书中读取 Team ID，使用固定源码构建 smartmontools 7.5，以同一个签名身份签名 App、Helper 和 companion，并在打包前检查严格签名以及两端的 `SMJobBless` signing requirements。Team ID 不是秘密，也不会被当作凭据使用。

免费的 Apple Development 证书会定期过期。续签后，导出新证书并更新这两个 secret 即可。只要 Personal Team ID 没有变化，App 与 Helper 的签名要求就不需要修改。

## 测试

```sh
# Core package tests
cd Packages/PalmosCore && swift test

# App target tests
xcodebuild test -workspace Palmos.xcworkspace \
  -scheme PalmosApp \
  -destination 'platform=macOS'
```

## 许可证

Palmos 使用 [MIT License](LICENSE) 发布，许可证也会随 App 一起打包。

### 第三方许可证

Palmos 使用 [MenuBarExtraAccess 1.3.0](https://github.com/orchetect/MenuBarExtraAccess)，该依赖按 MIT License 发布。完整许可证位于 [`Shared/Licensing/MenuBarExtraAccess-LICENSE.txt`](Shared/Licensing/MenuBarExtraAccess-LICENSE.txt)，也会随 App 一起打包。

Palmos Release 包含一个单独签名的 `smartctl` 可执行文件。它由 smartmontools 7.5 构建，并禁用了外部硬盘数据库，因此 root Helper 不会读取 `/usr/local` 或 Homebrew 路径中的配置和数据库文件。

smartmontools 使用 GNU GPL version 2 or later 发布。完整的上游许可证位于 [`Shared/Licensing/smartmontools-COPYING.txt`](Shared/Licensing/smartmontools-COPYING.txt)，也会随 App 一起打包。每个 GitHub Release 还会附带构建时实际使用、经过 checksum 固定的 `smartmontools-7.5.tar.gz` 对应源码归档。

固定的上游归档从 SourceForge 下载，其 SHA-256 必须为：

`690b83ca331378da9ea0d9d61008c4b22dde391387b9bbad7f29387f2595f76e`
