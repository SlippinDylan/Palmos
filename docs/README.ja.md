<div align="center">
  <img src="images/readme/app-icon.png" width="160" height="160" alt="Palmos のアプリアイコン">
  <h1>Palmos</h1>
  <p>外付け物理ストレージを監視する、macOS ネイティブのメニューバーアプリです。</p>
  <p>
    <a href="README.zh-CN.md">简体中文</a> ·
    <a href="README.zh-TW.md">繁體中文</a> ·
    <a href="../README.md">English</a> ·
    <strong>日本語</strong> ·
    <a href="README.ru.md">Русский</a>
  </p>
</div>

## Palmos について

Palmos は、接続中の外付けドライブの状態をメニューバーからすぐ確認できるようにします。ネイティブパネルには、容量、マウント済みボリューム、接続経路、リアルタイムの読み書き速度、安全な取り出し、オプションの SMART 健康状態と温度が表示されます。

最上位の単位は常に外付け物理デバイスです。内蔵ストレージ、ネットワークボリューム、仮想メディア、iPhone や iPad のマウントは表示しません。

## 機能

<table>
  <tr>
    <td width="32%">
      <strong>メニューバーからすぐ確認</strong><br><br>
      USB、Thunderbolt、USB4、SD、外付け SSD、HDD、NVMe ケースを自動検出し、コンパクトなネイティブパネルにまとめます。
    </td>
    <td width="68%" align="center"><img src="images/readme/menu-panel.png" width="406" alt="概要、スループット、容量、SMART、温度を表示する Palmos のメニューバーパネル"></td>
  </tr>
  <tr>
    <td>
      <strong>オプションの SMART 監視</strong><br><br>
      より広い SMART 健康状態と温度の取得が必要な場合だけ、権限を限定した Helper をインストールします。Helper がなくても他の機能は利用できます。
    </td>
    <td align="center"><img src="images/readme/smart-helper-settings.png" width="520" alt="SMART Helper がインストール済みの Palmos 設定"></td>
  </tr>
</table>

## 対応環境

| 項目 | 内容 |
|---|---|
| 対応デバイス | USB ストレージ、Thunderbolt / USB4、SD カード、外付け SSD / HDD、外付け NVMe ケース |
| 対象外 | 内蔵ストレージ、ネットワークボリューム、仮想メディア、iPhone / iPad マウント |
| 最小 OS | macOS 26 以降 |
| アーキテクチャ | Apple Silicon（arm64） |
| ビルド環境 | Xcode 26.4 以降と macOS 26 SDK |
| 配布形式 | Apple Development 署名済み、未公証の DMG を GitHub Releases で配布 |

## インストールとリリース

各 GitHub Release には arm64 専用の `Palmos-v<バージョン>.dmg` が 1 つ含まれます。DMG を開き、`Palmos.app` を `Applications` にドラッグしてください。リリースは無料の Apple Development 証明書で署名されていますが、公証は受けていません。初回起動前に隔離属性を削除します。

```bash
sudo xattr -rd com.apple.quarantine /Applications/Palmos.app
```

リリース設定は [`Config/Release/manifest.json`](../Config/Release/manifest.json) にあります。main CI の成功、`release: true`、未公開のバージョン、[CHANGELOG.md](../CHANGELOG.md) 内の一致する一意で空でないセクションが揃った場合だけ公開されます。

### Homebrew と App の更新

Sparkle 対応の GitHub Release が公開されると、固定 DMG checksum と署名済み appcast が共有 Tap に同期されます。

```bash
brew tap slippindylan/tap
brew trust --tap slippindylan/tap
brew install --cask palmos@beta
```

Stable は `palmos`、alpha は `palmos@alpha` を使用します。Palmos は Sparkle 2 でバックグラウンド更新確認を行い、設定 → About の「Check for Updates…」から手動確認もできます。署名済み appcast は `https://slippindylan.github.io/homebrew-tap/palmos/appcast.xml` です。

App の更新は `Palmos.app` だけを置き換えます。特権 SMART Helper と署名済み `smartctl` companion は更新しないため、互換性のために必要な場合は Settings → SMART Helper から管理者承認付きで明示的に更新してください。

`main` への push と Pull Request では、常に軽量なリリース自動化チェックを実行します。変更が `README.md`、`docs/`、`LICENSE`、`AGENTS.md` のみに限られる場合は macOS ビルドを省略しますが、公開が有効な場合は完全なチェックを強制します。それ以外の変更では Core、App、Helper のセキュリティ、パッケージング、未署名 arm64 ビルドを検証します。

## SMART Helper

オプションの Helper は `SMJobBless` を通じて `/Library/PrivilegedHelperTools/com.palmos.smartservice` にインストールされます。公開する機能は、バージョン交渉、上限付き SMART 読み取り、companion のインストール、上限付き使用中プロセス診断だけです。

App を削除しても Helper は自動削除されません。

```bash
sudo launchctl bootout system /Library/LaunchDaemons/com.palmos.smartservice.plist
sudo rm /Library/LaunchDaemons/com.palmos.smartservice.plist
sudo rm /Library/PrivilegedHelperTools/com.palmos.smartservice
sudo rm /Library/PrivilegedHelperTools/com.palmos.smartservice.smartctl
```

## ソースからビルド

`Palmos.xcworkspace` を開き、`PalmosApp` scheme を選択してください。SMART 対応のローカル App は、Apple Development 証明書を用意して次を実行します。

```bash
Scripts/build-local-smart-app.sh
```

## ライセンス

Copyright © 2025–2026 SlippinDylan Studio. Palmos は [Apache License 2.0](../LICENSE) で公開されています。

Palmos には MIT License の MenuBarExtraAccess 1.3.0 と、GPL version 2 or later の smartmontools 7.5 からビルドした `smartctl` が含まれます。完全な通知は [`Shared/Licensing`](../Shared/Licensing) にあります。
