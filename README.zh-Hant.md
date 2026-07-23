# Palmos

[简体中文](README.md) | **繁體中文** | [English](README.en.md)

Palmos 是一款 macOS 選單列 App，用來監控已連接的外接實體儲存裝置。它會在原生選單列視窗中顯示裝置健康狀態、連線資訊、容量、已掛載卷宗和即時讀寫速度。

## 系統需求

- macOS 15 或更新版本
- Xcode 26.4 或更新版本，並安裝 macOS 26 SDK（從原始碼建置時需要）

## 支援的裝置

- USB 儲存裝置
- Thunderbolt / USB4 儲存裝置
- SD 卡儲存裝置
- 外接 SSD 和 HDD
- 外接 NVMe 硬碟盒

Palmos 不會顯示網路卷宗、內建儲存裝置，以及以類似方式掛載的 iPhone / iPad。

## 架構

Palmos 包含三個 target：

- **PalmosApp**：選單列 App、介面、裝置瀏覽、吞吐圖表、設定、登入時啟動和安全退出。
- **PalmosCore**：共用的領域模型與應用程式邏輯，不依賴 UI 或特權能力。
- **PalmosSMARTService**：透過 `SMJobBless` 安裝、經 XPC 呼叫的特權 Helper。它只處理 SMART 相關操作，並負責安裝由 Palmos 簽署的 `smartctl` companion。

沒有安裝特權 Helper 時，App 的其他功能仍可正常使用。SMART 是分層提供、由使用者選擇啟用的能力。

## 安裝 GitHub Release

Palmos Release 使用免費的 Apple Development 憑證，讓 App 和特權 Helper 能夠互相驗證。Release 未經 Apple 公證，因此將 `PalmosApp.app` 移到 `/Applications` 後，需要執行一次以下指令來移除下載隔離屬性：

```sh
sudo xattr -rd com.apple.quarantine /Applications/PalmosApp.app
```

這個遞迴指令也會處理 App 套件內嵌的 Helper。不要把 Helper 單獨複製出來，也不需要再對它執行一次 `xattr`。正常開啟 Palmos，需要時再到設定中安裝 SMART Helper。

移除隔離屬性只會略過 Gatekeeper 對下載檔案的隔離檢查，不能取代程式碼簽署。Release workflow 會使用同一個 Apple Development Team 簽署 App 和 Helper。

## 特權 SMART Helper

首次要求進階 SMART 監控時，Palmos 會安裝特權 Helper。Apple 的 App sandbox API 無法讀取大多數外接硬碟盒的 SMART 遙測資料，因此要涵蓋更多 Thunderbolt 和 USB 硬碟盒，需要使用這個 Helper。

Helper 安裝在 `/Library/PrivilegedHelperTools/com.palmos.smartservice`，並註冊為 launchd daemon。安裝時系統會要求輸入管理員憑證。Helper 驗證固定的程式碼簽署識別碼和一致的 Team ID 後，同一流程才會把隨套件提供的 companion 安裝到 `/Library/PrivilegedHelperTools/com.palmos.smartservice.smartctl`。安裝後的檔案歸 root 所有，Palmos 不會從 Homebrew 或其他使用者可寫入的指令路徑載入它。

### Helper 版本相容性

每次執行 SMART 操作前，App 都會檢查 XPC contract 的相容性：

- **主版本不一致**：阻止 SMART 操作，並要求更新。
- **次版本不一致**：降級執行；共用 contract 支援的 SMART 功能仍然可用。

### 移除 Helper

刪除 App 本身**不會**自動移除特權 Helper。目前版本還沒有提供解除安裝按鈕，請在刪除 Palmos 前後手動執行：

```sh
sudo launchctl bootout system /Library/LaunchDaemons/com.palmos.smartservice.plist
sudo rm /Library/LaunchDaemons/com.palmos.smartservice.plist
sudo rm /Library/PrivilegedHelperTools/com.palmos.smartservice
sudo rm /Library/PrivilegedHelperTools/com.palmos.smartservice.smartctl
```

## 從原始碼建置

在 Xcode 中開啟 `Palmos.xcworkspace`，選擇 `PalmosApp` scheme 後建置。
未簽署版本可以在不使用 SMART 的情況下執行；特權 SMART 路徑要求穩定的程式碼簽署身分，以便 App、Helper 和 `smartctl` companion 互相驗證。

`PalmosSMARTService` scheme 用來建置特權 Helper。儲存庫預設使用維護者公開的 Team ID。免費 Personal Team 使用者可以在 Xcode 的 **Settings → Accounts → Manage Certificates** 中建立 Apple Development 憑證。本機使用不需要付費加入 Apple Developer Program，也不需要 Developer ID 憑證或 Apple 公證。

Pull Request 測試會在命令列中明確停用簽署，本機編譯和測試也可以這樣做。凡是需要執行 SMART Helper 的建置，都必須用同一個免費 Apple Development Team 簽署 App、Helper 和 companion。

一般 Debug 建置不會下載第三方工具。建立 Apple Development 憑證後，可以用專用指令碼建置支援 SMART 的本機 App：

```sh
Scripts/build-local-smart-app.sh
```

如果機器上有多個 Apple Development 簽署身分，先用以下指令列出 SHA-1：

```sh
security find-identity -v -p codesigning
```

再明確選擇其中一個：

```sh
Scripts/build-local-smart-app.sh --identity APPLE_DEVELOPMENT_SHA1
```

指令碼每次都會在隔離目錄中，從固定版本且經過 SHA 驗證的原始碼封存檔重新建置 smartctl。它會簽署新產生的二進位檔，將簽署後的 SHA-256 傳給 Helper，再使用從 companion 簽署中擷取的 Team ID 建置全部元件並執行完整簽署檢查。驗證通過的 companion 會放到 `DerivedData/LocalSMART` 下不可變的摘要命名路徑；只有所有檢查都通過後，指令碼才會以不可分割的方式取代被 Git 忽略的 `Config/xcconfigs/Local.xcconfig`。之後從 Xcode 執行 **Cmd+R** 會重複使用這個已驗證的 companion 和 Personal Team；命令列明確停用簽署時則不會嵌入它。指令碼最後會輸出可以啟動的 `.app` 完整路徑。

如果所選 Personal Team 與已安裝 Helper 的 Team ID 不一致，請先按照[移除 Helper](#移除-helper)中的指令清理舊版本，再從新的建置安裝。已安裝的 Helper 只授權原 Team 的用戶端，本機建置指令碼不會自動執行具破壞性的系統清理。

Release workflow 會在 CI 中執行等價流程。如果 companion、簽署、授權條款或原始碼封存檔缺少，建置會直接失敗。

### GitHub Release 簽署

Release workflow 需要設定兩個 GitHub Actions secret：

- `APPLE_DEVELOPMENT_P12_BASE64`：匯出的 Apple Development 憑證及私密金鑰，以 base64 編碼。
- `APPLE_DEVELOPMENT_P12_PASSWORD`：P12 檔案的匯出密碼。

例如，將憑證匯出為 `AppleDevelopment.p12` 後，可以用以下指令複製編碼內容：

```sh
base64 -i AppleDevelopment.p12 | pbcopy
```

在儲存庫的 **Settings → Secrets and variables → Actions** 中加入編碼內容和匯出密碼。Workflow 會從憑證中讀取 Team ID，使用固定原始碼建置 smartmontools 7.5，以同一個簽署身分簽署 App、Helper 和 companion，並在封裝前檢查嚴格簽署以及兩端的 `SMJobBless` signing requirements。Team ID 不是秘密，也不會被當作憑證使用。

免費的 Apple Development 憑證會定期過期。續簽後，匯出新憑證並更新這兩個 secret 即可。只要 Personal Team ID 沒有變更，App 與 Helper 的簽署要求就不需要修改。

## 測試

```sh
# Core package tests
cd Packages/PalmosCore && swift test

# App target tests
xcodebuild test -workspace Palmos.xcworkspace \
  -scheme PalmosApp \
  -destination 'platform=macOS'
```

## 授權條款

Palmos 依照 [MIT License](LICENSE) 發布，授權條款也會隨 App 一起封裝。

### 第三方授權條款

Palmos 使用 [MenuBarExtraAccess 1.3.0](https://github.com/orchetect/MenuBarExtraAccess)，該相依套件依照 MIT License 發布。完整授權條款位於 [`Shared/Licensing/MenuBarExtraAccess-LICENSE.txt`](Shared/Licensing/MenuBarExtraAccess-LICENSE.txt)，也會隨 App 一起封裝。

Palmos Release 包含一個單獨簽署的 `smartctl` 可執行檔。它由 smartmontools 7.5 建置，並停用了外部硬碟資料庫，因此 root Helper 不會讀取 `/usr/local` 或 Homebrew 路徑中的設定和資料庫檔案。

smartmontools 依照 GNU GPL version 2 or later 發布。完整的上游授權條款位於 [`Shared/Licensing/smartmontools-COPYING.txt`](Shared/Licensing/smartmontools-COPYING.txt)，也會隨 App 一起封裝。每個 GitHub Release 還會附帶建置時實際使用、經過 checksum 固定的 `smartmontools-7.5.tar.gz` 對應原始碼封存檔。

固定的上游封存檔從 SourceForge 下載，其 SHA-256 必須為：

`690b83ca331378da9ea0d9d61008c4b22dde391387b9bbad7f29387f2595f76e`
