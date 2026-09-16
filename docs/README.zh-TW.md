<div align="center">
  <img src="images/readme/app-icon.png" width="160" height="160" alt="Palmos App 圖示">
  <h1>Palmos</h1>
  <p>原生 macOS 選單列 App，用來監控外接實體儲存裝置。</p>
  <p>
    <a href="README.zh-CN.md">简体中文</a> ·
    <strong>繁體中文</strong> ·
    <a href="../README.md">English</a> ·
    <a href="README.ja.md">日本語</a> ·
    <a href="README.ru.md">Русский</a>
  </p>
</div>

## Palmos 是什麼

Palmos 把外接硬碟的狀態放進選單列。開啟原生面板即可查看容量、已掛載卷宗、連線鏈路、即時讀寫、安全退出，以及可選的 SMART 健康與溫度資料。

頂層物件始終是外接實體裝置，卷宗與分割區顯示在裝置下方。Palmos 不顯示內建儲存、網路卷宗、虛擬磁碟，以及 iPhone 或 iPad 掛載。

## 功能

<table>
  <tr>
    <td width="32%">
      <strong>常駐選單列</strong><br><br>
      自動探索 USB、Thunderbolt、USB4、SD、外接 SSD、HDD 和 NVMe 硬碟盒，需要時開啟緊湊的原生面板。
    </td>
    <td width="68%" align="center"><img src="images/readme/menu-panel.png" width="406" alt="顯示概覽、吞吐、容量、SMART 和溫度資料的 Palmos 選單列面板"></td>
  </tr>
  <tr>
    <td>
      <strong>可選 SMART 監控</strong><br><br>
      需要更廣泛的 SMART 健康與溫度涵蓋時，再安裝權限範圍受控的 Helper。未安裝 Helper 時，其他功能仍然可用。
    </td>
    <td align="center"><img src="images/readme/smart-helper-settings.png" width="520" alt="顯示 SMART Helper 已安裝的 Palmos 設定"></td>
  </tr>
</table>

## 支援範圍

| 項目 | 內容 |
|---|---|
| 支援裝置 | USB 儲存、Thunderbolt / USB4 儲存、SD 卡、外接 SSD 和 HDD、外接 NVMe 硬碟盒 |
| 排除裝置 | 內建儲存、網路卷宗、虛擬磁碟、iPhone 和 iPad 掛載 |
| 頂層模型 | 外接實體裝置，已掛載卷宗顯示在裝置下方 |
| 最低系統 | macOS 26 或更新版本 |
| 架構 | Apple 晶片（arm64） |
| 建置環境 | Xcode 26.4 或更新版本，並安裝 macOS 26 SDK |
| 發佈方式 | GitHub Releases 提供 Apple Development 簽署、未經公證的 DMG |

## 安裝與發佈

每個 GitHub Release 只包含一個 arm64 成品 `Palmos-v<版本號>.dmg`。開啟 DMG，把 `Palmos.app` 拖入 `Applications`。Release 使用免費的 Apple Development 憑證，使 App、特權 Helper 和隨套件提供的 `smartctl` companion 能夠互相驗證。目前 Release 未經 Apple 公證，第一次開啟前需要移除下載隔離屬性：

```bash
sudo xattr -rd com.apple.quarantine /Applications/Palmos.app
```

移除隔離屬性不能取代程式碼簽署驗證。正常開啟 Palmos，只在需要 SMART 時從設定中安裝 Helper。

發佈設定位於 [`Config/Release/manifest.json`](../Config/Release/manifest.json)。只有 main CI 成功、`release` 為 `true`、版本尚未發佈，且 [CHANGELOG.md](../CHANGELOG.md) 存在唯一、非空且完全同名的版本章節時，Release workflow 才會簽署、封裝及發佈。版本支援 `x.y.z`、`x.y.z-alpha.n` 和 `x.y.z-beta.n`。

發佈自動化使用以下 GitHub Actions repository secrets：

- `CERTIFICATES_P12`：Apple Development P12 的 Base64 內容
- `CERTIFICATES_PASSWORD`：P12 匯出密碼
- `FEISHU_WEBHOOK`：飛書自訂機器人 Webhook
- `FEISHU_SECRET`：飛書自訂機器人簽署密鑰

舊的憑證 secret 名稱 `APPLE_DEVELOPMENT_P12_BASE64` 和 `APPLE_DEVELOPMENT_P12_PASSWORD` 仍然相容。

## 特權 SMART Helper

可選 Helper 透過 `SMJobBless` 安裝至 `/Library/PrivilegedHelperTools/com.palmos.smartservice`。它只提供版本協商、有界 SMART 讀取、companion 安裝和有界佔用診斷。Companion 安裝至 `/Library/PrivilegedHelperTools/com.palmos.smartservice.smartctl`；Palmos 不會從 Homebrew 或其他使用者可寫入路徑載入 `smartctl`。

每次 SMART 操作前都會檢查 XPC 相容性：

- 主版本不一致會阻止操作並要求更新。
- 次版本不一致會降級到兩端共同支援的能力。

刪除 App 不會自動刪除 Helper。請在刪除 Palmos 前後手動執行：

```bash
sudo launchctl bootout system /Library/LaunchDaemons/com.palmos.smartservice.plist
sudo rm /Library/LaunchDaemons/com.palmos.smartservice.plist
sudo rm /Library/PrivilegedHelperTools/com.palmos.smartservice
sudo rm /Library/PrivilegedHelperTools/com.palmos.smartservice.smartctl
```

## 從原始碼建置

開啟 `Palmos.xcworkspace`，選擇 `PalmosApp` scheme 後建置。未簽署版本可以在不使用 SMART 的情況下執行；SMART 路徑要求 App、Helper 和 companion 使用同一個 Apple Development Team。

建立 Apple Development 簽署身分後，執行：

```bash
Scripts/build-local-smart-app.sh
```

指令碼會從固定且經 checksum 驗證的原始碼重新建置 smartctl 7.5，簽署後把 SHA-256 傳給 Helper，再使用從簽署中擷取的 Team ID 建置全部元件並執行完整簽署檢查。指令碼不會自動清理其他 Team 已安裝的 Helper。

## 測試

```bash
cd Packages/PalmosCore && swift test

xcodebuild test \
  -workspace Palmos.xcworkspace \
  -scheme PalmosApp \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
```

所有 push 和 Pull Request 都會在 CI 中執行 Core、App、Helper 安全、封裝和自動化檢查。

## 授權條款

Copyright © 2025–2026 SlippinDylan Studio。Palmos 採用 [Apache License 2.0](../LICENSE) 開放原始碼授權條款。

### 第三方授權條款

Palmos 隨套件提供依照 MIT License 發佈的 [MenuBarExtraAccess 1.3.0](https://github.com/orchetect/MenuBarExtraAccess)，以及由 smartmontools 7.5 建置、依照 GPL version 2 or later 發佈並單獨簽署的 `smartctl`。完整聲明位於 [`Shared/Licensing`](../Shared/Licensing)，也會包含在 App 中。

對應的 smartmontools 原始碼封存檔內嵌於 `Palmos.app/Contents/Resources/ThirdPartySources/smartmontools-7.5.tar.gz`，要求的 SHA-256 為 `690b83ca331378da9ea0d9d61008c4b22dde391387b9bbad7f29387f2595f76e`。
