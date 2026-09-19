<div align="center">
  <img src="docs/images/readme/app-icon.png" width="160" height="160" alt="Palmos app icon">
  <h1>Palmos</h1>
</div>

<div align="center">
  <p>A native macOS menu-bar app for external physical storage.</p>
  <p><a href="docs/README.zh-CN.md">简体中文</a> · <a href="docs/README.zh-TW.md">繁體中文</a> · <strong>English</strong> · <a href="docs/README.ja.md">日本語</a> · <a href="docs/README.ru.md">Русский</a></p>
</div>

Palmos puts the information you need before unplugging an external drive in the menu bar. It treats the physical device as the main item, then shows its volumes and partitions beneath it. A multi-volume APFS drive stays one drive in the list.

<table>
  <tr><td width="32%"><strong>At a glance</strong><br><br>See live read and write throughput, session totals, capacity, mounted volumes, and the connection path without opening Disk Utility.</td><td width="68%" align="center"><img src="docs/images/readme/menu-panel.png" width="406" alt="Palmos menu-bar panel showing device overview, throughput, capacity, SMART, and temperature"></td></tr>
  <tr><td><strong>SMART when it is available</strong><br><br>Install the optional SMART Helper from Settings when you need SMART health or temperature readings. The rest of Palmos works without it.</td><td align="center"><img src="docs/images/readme/smart-helper-settings.png" width="520" alt="Palmos settings showing the SMART Helper"></td></tr>
</table>

## What it shows

- Live read and write speed, plus counters for the current connection session.
- Total, used, and available capacity; mounted volumes, file systems, and partitions.
- USB, Thunderbolt, USB4, SD, or supported PCIe-tunnelled connection information.
- A Safe Eject action for the whole physical device. Palmos unmounts it before ejecting it and only reports that it is safe to remove after eject succeeds. If macOS says the device is busy, Palmos can help identify holders before you choose what to do.

## Supported devices

Palmos supports external physical storage connected through USB, Thunderbolt, USB4, SD, and supported PCIe-tunnelled NVMe enclosures. That includes external SSDs, HDDs, SD cards, and external NVMe enclosures. An unmounted physical device can still appear in the list.

It intentionally excludes internal storage, network volumes, virtual media, and iPhone or iPad mounts. It requires macOS 26 or later on Apple Silicon (arm64).

SMART is different from device discovery: a drive and its enclosure or adapter must both expose the required commands. Some USB-to-SATA/NVMe bridges do not pass SMART through, or need a transport mode Palmos cannot use. In those cases Palmos shows SMART as unavailable or reports that transport support is needed; installing the Helper cannot change the bridge hardware.

## Install and first use

### Homebrew

```bash
brew tap slippindylan/tap
brew trust --tap slippindylan/tap
brew install --cask palmos@beta
```

### DMG and first launch

1. Download the arm64 DMG from [GitHub Releases](https://github.com/SlippinDylan/Palmos/releases), open it, and drag `Palmos.app` to `Applications`.
2. Current releases are signed with an Apple Development certificate but are not notarized. macOS may retain its download quarantine and refuse the first launch for that reason. If that happens, remove the quarantine attribute from the app you installed:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Palmos.app
   ```

3. Open Palmos, connect an external drive, and click its menu-bar icon. Select a device to view its volumes, capacity, throughput, topology, and eject control.

Palmos follows the macOS app language by default. In **Settings → General**, you can explicitly choose English, Simplified Chinese, or Traditional Chinese; changing the app language requires a restart.

The command only removes the download-quarantine attribute from `/Applications/Palmos.app`; it does not bypass code-signature checks. Do not run it against an app you do not trust.

## SMART Helper and updates

The SMART Helper is optional. When the SMART section asks for it, choose **Install Helper** in Settings and approve the macOS administrator prompt. Palmos installs its own trusted `smartctl` companion with the Helper; it does not use a Homebrew or user-writable copy.

Palmos checks for app updates automatically, and **Settings → About → Check for Updates…** starts a check manually. An app update replaces `Palmos.app` only. It does not silently install or update the privileged Helper, so revisit **Settings → SMART Helper** if Palmos asks you to update it.

Deleting `Palmos.app` does not remove an installed Helper. To remove the Helper as well, run these commands only after you have decided to uninstall Palmos. They target the named Palmos system service and companion, not your disks or their data:

```bash
sudo launchctl bootout system /Library/LaunchDaemons/com.palmos.smartservice.plist
sudo rm /Library/LaunchDaemons/com.palmos.smartservice.plist
sudo rm /Library/PrivilegedHelperTools/com.palmos.smartservice
sudo rm /Library/PrivilegedHelperTools/com.palmos.smartservice.smartctl
```

## Build from source

Open `Palmos.xcworkspace` in Xcode 26.4 or later with the macOS 26 SDK, select the `PalmosApp` scheme, and build. An unsigned build works without SMART. To build an app with the SMART path, the app, Helper, and companion must use the same Apple Development Team; after configuring that identity, run:

```bash
Scripts/build-local-smart-app.sh
```

## License

Copyright © 2025–2026 SlippinDylan Studio. Palmos is released under the [Apache License 2.0](LICENSE).

The app includes [MenuBarExtraAccess 1.3.0](https://github.com/orchetect/MenuBarExtraAccess) under the MIT License and `smartctl`, built from smartmontools 7.5, under GPL version 2 or later. Their notices are in [Shared/Licensing](Shared/Licensing).
