<div align="center">
  <img src="images/readme/app-icon.png" width="160" height="160" alt="Palmos App 圖示">
  <h1>Palmos</h1>
</div>

<div align="center">
  <p>用於查看外接實體儲存裝置的原生 macOS 選單列 App。</p>
  <p><a href="README.zh-CN.md">简体中文</a> · <strong>繁體中文</strong> · <a href="../README.md">English</a> · <a href="README.ja.md">日本語</a> · <a href="README.ru.md">Русский</a></p>
</div>

Palmos 把拔除外接硬碟前需要確認的資訊放進選單列。它以實體裝置為頂層，卷宗與分割區顯示在裝置下方；有多個卷宗的 APFS 磁碟仍會以一塊磁碟顯示。

<table>
  <tr><td width="32%"><strong>一眼看清</strong><br><br>無須開啟磁碟工具，即可查看即時讀寫吞吐量、目前連線工作階段的累計量、容量、已掛載卷宗與連線鏈路。</td><td width="68%" align="center"><img src="images/readme/menu-panel.png" width="406" alt="顯示裝置概覽、吞吐量、容量、SMART 和溫度的 Palmos 選單列面板"></td></tr>
  <tr><td><strong>可用時讀取 SMART</strong><br><br>需要 SMART 健康狀態或溫度資料時，可在設定中安裝選用的 SMART Helper。未安裝時，Palmos 的其他功能仍可使用。</td><td align="center"><img src="images/readme/smart-helper-settings.png" width="520" alt="顯示 SMART Helper 的 Palmos 設定"></td></tr>
</table>

## 可以查看什麼

- 即時讀寫速度，以及目前連線工作階段的累計讀寫量。
- 總容量、已用與可用容量；已掛載卷宗、檔案系統與分割區。
- USB、Thunderbolt、USB4、SD 或受支援 PCIe 隧道連線資訊。
- 針對整個實體裝置的安全退出。Palmos 會先卸載，再退出；只有退出成功才會提示可以移除。若 macOS 回報裝置正被使用，Palmos 可協助找出佔用者，讓你決定下一步。

## 支援裝置

Palmos 支援透過 USB、Thunderbolt、USB4、SD 以及受支援 PCIe 隧道連接的外接實體儲存，包括外接 SSD、HDD、SD 卡與外接 NVMe 硬碟盒。未掛載的實體裝置也可能顯示在列表中。

它不會顯示內建儲存、網路卷宗、虛擬媒體，以及 iPhone 或 iPad 掛載。需要 Apple 晶片（arm64）與 macOS 26 或更新版本。

SMART 與裝置探索不同：硬碟本身和硬碟盒或轉接器都必須能傳遞相應命令。有些 USB 轉 SATA/NVMe 橋接晶片不會傳遞 SMART，或需要 Palmos 尚不支援的傳輸模式。遇到這種情況，Palmos 會顯示 SMART 無法使用或需要傳輸支援；安裝 Helper 無法改變橋接硬體的能力。

## 安裝與首次使用

### Homebrew

```bash
brew tap slippindylan/tap
brew trust --tap slippindylan/tap
brew install --cask palmos@beta
```

### DMG 與首次啟動

1. 從 [GitHub Releases](https://github.com/SlippinDylan/Palmos/releases) 下載 arm64 DMG，開啟後將 `Palmos.app` 拖到 `Applications`。
2. 目前 Release 使用 Apple Development 憑證簽署，但未經公證。macOS 可能因下載隔離屬性阻止首次啟動；遇到這種情況，可只對已安裝的 App 移除此屬性：

   ```bash
   xattr -dr com.apple.quarantine /Applications/Palmos.app
   ```

3. 開啟 Palmos，連接外接硬碟並按一下選單列圖示。選取裝置後，即可查看卷宗、容量、吞吐量、拓撲與退出控制。

Palmos 預設跟隨 macOS 的 App 語言。你也可以在**設定 → 一般**中明確選擇 English、简体中文或繁體中文；更改 App 語言後需要重新啟動。

這個指令只會移除 `/Applications/Palmos.app` 的下載隔離屬性，不能略過程式碼簽署檢查。請勿對不信任的 App 執行它。

## SMART Helper 與更新

SMART Helper 是選用元件。SMART 區域要求安裝時，在設定中選擇「Install Helper」，並通過 macOS 的管理者授權。Palmos 會隨 Helper 安裝自己的受信任 `smartctl` 隨附工具，不會使用 Homebrew 或使用者可寫入目錄中的版本。

Palmos 會自動檢查 App 更新；也可在「Settings → About → Check for Updates…」手動檢查。App 更新只會替換 `Palmos.app`，不會自動安裝或更新特權 Helper。若 Palmos 要求更新 Helper，請回到「Settings → SMART Helper」操作。

刪除 `Palmos.app` 不會移除已安裝的 Helper。如需一併解除安裝，請在確定不再使用 Palmos 後才執行以下指令。它們只針對列出的 Palmos 系統服務與隨附工具，不會操作你的磁碟或資料：

```bash
sudo launchctl bootout system /Library/LaunchDaemons/com.palmos.smartservice.plist
sudo rm /Library/LaunchDaemons/com.palmos.smartservice.plist
sudo rm /Library/PrivilegedHelperTools/com.palmos.smartservice
sudo rm /Library/PrivilegedHelperTools/com.palmos.smartservice.smartctl
```

## 從原始碼建置

使用安裝 macOS 26 SDK 的 Xcode 26.4 或更新版本開啟 `Palmos.xcworkspace`，選擇 `PalmosApp` scheme 後建置。未簽署建置可在不使用 SMART 的情況下執行。若要建置有 SMART 的 App，App、Helper 與 companion 必須使用同一個 Apple Development Team；設定好簽署身分後執行：

```bash
Scripts/build-local-smart-app.sh
```

## 授權條款

Copyright © 2025–2026 SlippinDylan Studio。Palmos 採用 [Apache License 2.0](../LICENSE)。

App 包含依 MIT License 發布的 [MenuBarExtraAccess 1.3.0](https://github.com/orchetect/MenuBarExtraAccess)，以及由 smartmontools 7.5 建置、依 GPL version 2 or later 發布的 `smartctl`。完整聲明位於 [Shared/Licensing](../Shared/Licensing)。
