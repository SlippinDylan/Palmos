<div align="center">
  <img src="images/readme/app-icon.png" width="160" height="160" alt="Palmos のアプリアイコン">
  <h1>Palmos</h1>
</div>

<div align="center">
  <p>外付け物理ストレージを確認する macOS ネイティブのメニューバーアプリです。</p>
  <p><a href="README.zh-CN.md">简体中文</a> · <a href="README.zh-TW.md">繁體中文</a> · <a href="../README.md">English</a> · <strong>日本語</strong> · <a href="README.ru.md">Русский</a></p>
</div>

Palmos は、外付けドライブを取り外す前に確認したい情報をメニューバーに表示します。最上位の項目は物理デバイスで、その下にボリュームとパーティションを表示します。複数ボリュームの APFS ドライブも、リストでは 1 台のドライブのままです。

<table>
  <tr><td width="32%"><strong>ひと目で確認</strong><br><br>ディスクユーティリティを開かずに、リアルタイムの読み書きスループット、現在の接続セッションの合計、容量、マウント済みボリューム、接続経路を確認できます。</td><td width="68%" align="center"><img src="images/readme/menu-panel.png" width="406" alt="デバイス概要、スループット、容量、SMART、温度を表示する Palmos のメニューバーパネル"></td></tr>
  <tr><td><strong>利用可能な場合の SMART</strong><br><br>SMART の健康状態や温度が必要なときは、設定から任意の SMART Helper をインストールします。Helper がなくても Palmos のほかの機能は使えます。</td><td align="center"><img src="images/readme/smart-helper-settings.png" width="520" alt="SMART Helper を表示する Palmos の設定"></td></tr>
</table>

## 表示する情報

- リアルタイムの読み書き速度と、現在の接続セッションの累計値。
- 合計・使用済み・空き容量、マウント済みボリューム、ファイルシステム、パーティション。
- USB、Thunderbolt、USB4、SD、または対応する PCIe トンネリングの接続情報。
- 物理デバイス全体に対する安全な取り出し。Palmos は先にアンマウントしてから取り出し、成功するまで「取り外しても安全」と表示しません。macOS が使用中と報告した場合は、次の操作を選ぶ前に占有しているプロセスの特定を支援します。

## 対応デバイス

Palmos は USB、Thunderbolt、USB4、SD、および対応する PCIe トンネリングで接続された外付け物理ストレージに対応します。外付け SSD、HDD、SD カード、外付け NVMe ケースが含まれます。アンマウント済みの物理デバイスもリストに表示されることがあります。

内蔵ストレージ、ネットワークボリューム、仮想メディア、iPhone / iPad のマウントは対象外です。Apple Silicon（arm64）搭載、macOS 26 以降が必要です。

SMART はデバイス検出とは別です。ドライブ本体とケースまたはアダプタの両方が必要なコマンドを通す必要があります。一部の USB-SATA/NVMe ブリッジは SMART をパススルーしないか、Palmos が使えない転送モードを必要とします。その場合は SMART が利用できない、または転送サポートが必要と表示されます。Helper をインストールしても、ブリッジのハードウェア機能は変わりません。

## インストールと初回使用

### Homebrew

```bash
brew tap slippindylan/tap
brew trust --tap slippindylan/tap
brew install --cask palmos@beta
```

### DMG と初回起動

1. [GitHub Releases](https://github.com/SlippinDylan/Palmos/releases) から arm64 DMG をダウンロードし、開いて `Palmos.app` を `Applications` にドラッグします。
2. 現在のリリースは Apple Development 証明書で署名されていますが、公証されていません。macOS がダウンロード時の隔離属性のため初回起動を拒否する場合は、インストールした App だけからその属性を外します。

   ```bash
   xattr -dr com.apple.quarantine /Applications/Palmos.app
   ```

3. Palmos を開き、外付けドライブを接続してメニューバーアイコンをクリックします。デバイスを選ぶと、ボリューム、容量、スループット、トポロジー、取り出し操作を確認できます。

Palmos はデフォルトで macOS のアプリ言語に従います。**設定 → 一般**では English、简体中文、繁體中文を明示的に選択できます。アプリ言語の変更後は再起動が必要です。

このコマンドは `/Applications/Palmos.app` のダウンロード隔離属性だけを削除します。コード署名の検証を回避するものではありません。信頼できない App には実行しないでください。

## SMART Helper と更新

SMART Helper は任意です。SMART セクションに求められたら、Settings で **Install Helper** を選び、macOS の管理者認証を許可します。Palmos は Helper とともに独自の信頼済み `smartctl` companion をインストールし、Homebrew やユーザー書き込み可能な場所のコピーは使いません。

Palmos は App の更新を自動で確認します。**Settings → About → Check for Updates…** から手動確認もできます。App の更新は `Palmos.app` だけを置き換え、特権 Helper を勝手にインストールまたは更新しません。Helper の更新を求められた場合は **Settings → SMART Helper** に戻って操作してください。

`Palmos.app` を削除しても、インストール済みの Helper は削除されません。Helper も削除する場合は、Palmos をアンインストールすると決めてから次のコマンドを実行してください。これらは名前が示す Palmos のシステムサービスと companion だけを対象とし、ディスクやデータには作用しません。

```bash
sudo launchctl bootout system /Library/LaunchDaemons/com.palmos.smartservice.plist
sudo rm /Library/LaunchDaemons/com.palmos.smartservice.plist
sudo rm /Library/PrivilegedHelperTools/com.palmos.smartservice
sudo rm /Library/PrivilegedHelperTools/com.palmos.smartservice.smartctl
```

## ソースからビルド

macOS 26 SDK を含む Xcode 26.4 以降で `Palmos.xcworkspace` を開き、`PalmosApp` scheme を選んでビルドします。未署名ビルドは SMART なしで動作します。SMART 対応 App をビルドするには、App、Helper、companion が同じ Apple Development Team を使う必要があります。署名 ID を設定した後、次を実行します。

```bash
Scripts/build-local-smart-app.sh
```

## ライセンス

Copyright © 2025–2026 SlippinDylan Studio. Palmos は [Apache License 2.0](../LICENSE) で公開されています。

App には MIT License の [MenuBarExtraAccess 1.3.0](https://github.com/orchetect/MenuBarExtraAccess) と、GPL version 2 or later の smartmontools 7.5 からビルドした `smartctl` が含まれます。通知は [Shared/Licensing](../Shared/Licensing) にあります。
