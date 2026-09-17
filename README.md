<div align="center">
  <img src="docs/images/readme/app-icon.png" width="160" height="160" alt="Palmos app icon">
  <h1>Palmos</h1>
  <p>A native macOS menu-bar app for monitoring external physical storage devices.</p>
  <p>
    <a href="docs/README.zh-CN.md">简体中文</a> ·
    <a href="docs/README.zh-TW.md">繁體中文</a> ·
    <strong>English</strong> ·
    <a href="docs/README.ja.md">日本語</a> ·
    <a href="docs/README.ru.md">Русский</a>
  </p>
</div>

## What It Is

Palmos keeps the state of connected external drives one click away. Its native menu-bar panel presents capacity, mounted volumes, connection topology, live read/write throughput, safe-eject controls, and optional SMART health data without turning individual volumes into separate devices.

The top-level object is always the external physical device. Network volumes, internal storage, virtual media, and iPhone or iPad mounts are excluded.

## Features

<table>
  <tr>
    <td width="32%">
      <strong>Ready in the menu bar</strong><br><br>
      Palmos watches for supported USB, Thunderbolt, USB4, SD, SSD, HDD, and NVMe storage, then opens a compact native panel when you need it.
    </td>
    <td width="68%" align="center"><img src="docs/images/readme/menu-panel.png" width="406" alt="Palmos menu-bar panel showing overview, throughput, capacity, SMART, and temperature data"></td>
  </tr>
  <tr>
    <td>
      <strong>Optional SMART monitoring</strong><br><br>
      Install the narrowly scoped privileged helper when you need broader SMART health and temperature coverage. The rest of the app remains available without it.
    </td>
    <td align="center"><img src="docs/images/readme/smart-helper-settings.png" width="520" alt="Palmos settings showing the installed SMART Helper"></td>
  </tr>
</table>

## Supported Devices

| | |
|---|---|
| Supported | USB storage, Thunderbolt / USB4 storage, SD cards, external SSDs and HDDs, external NVMe enclosures |
| Excluded | Internal storage, network volumes, virtual media, iPhone and iPad mounts |
| Top-level model | External physical device, with mounted volumes shown underneath |
| Minimum system | macOS 26 or later |
| Architecture | Apple Silicon (arm64) |
| Build toolchain | Xcode 26.4 or later with the macOS 26 SDK |
| Distribution | Apple Development-signed, non-notarized DMG from GitHub Releases |

## Installation and Releases

Each GitHub Release contains one arm64-only `Palmos-v<version>.dmg`. Open the DMG and drag `Palmos.app` into `Applications`. Releases use a free Apple Development certificate so the app, privileged helper, and bundled `smartctl` companion can authenticate each other. They are not notarized, so remove the installed bundle's quarantine attribute once before the first launch:

```bash
sudo xattr -rd com.apple.quarantine /Applications/Palmos.app
```

Removing quarantine does not replace code-signing verification. Open Palmos normally, then install the SMART Helper from Settings only if you need it.

Release configuration lives in [`Config/Release/manifest.json`](Config/Release/manifest.json). Publishing requires successful main CI, `release: true`, an unpublished version, and one unique non-empty matching section in [CHANGELOG.md](CHANGELOG.md). Supported versions are `x.y.z`, `x.y.z-alpha.n`, and `x.y.z-beta.n`.

Release automation uses these GitHub Actions repository secrets:

- `CERTIFICATES_P12`: Base64-encoded Apple Development P12
- `CERTIFICATES_PASSWORD`: P12 export password
- `FEISHU_WEBHOOK`: Feishu custom bot webhook
- `FEISHU_SECRET`: Feishu custom bot signing secret

The legacy `APPLE_DEVELOPMENT_P12_BASE64` and `APPLE_DEVELOPMENT_P12_PASSWORD` certificate secret names remain accepted.

- `SPARKLE_ED_PRIVATE_KEY`: Sparkle EdDSA private update-signing key
- `HOMEBREW_TAP_TOKEN`: Fine-grained token with Contents write access only to `SlippinDylan/homebrew-tap`

### Homebrew

After a Sparkle-enabled GitHub Release is public, its immutable DMG checksum and signed appcast are published to the shared tap:

```bash
brew tap slippindylan/tap
brew trust --tap slippindylan/tap
brew install --cask palmos@beta
```

Stable releases use `palmos`; alpha releases use `palmos@alpha`. Casks are version-pinned to the matching GitHub Release DMG.

### App Updates

Palmos uses Sparkle 2 for automatic background checks and the **Check for Updates…** action in Settings → About. Sparkle verifies the EdDSA-signed update archive and signed public appcast at `https://slippindylan.github.io/homebrew-tap/palmos/appcast.xml`. Stable, beta, and alpha builds share that feed while receiving only their allowed channel updates.

An App update replaces only `Palmos.app`. It does not install or upgrade the privileged SMART Helper or its signed `smartctl` companion. Keep using Settings → SMART Helper, with macOS administrator approval, whenever Helper compatibility requires an explicit install or update.

## Privileged SMART Helper

The optional helper is installed through `SMJobBless` at `/Library/PrivilegedHelperTools/com.palmos.smartservice`. It exposes only version negotiation, bounded SMART reads, companion installation, and bounded occupancy diagnostics. The companion is installed at `/Library/PrivilegedHelperTools/com.palmos.smartservice.smartctl`; Palmos never loads `smartctl` from Homebrew or another user-writable path.

Before each SMART operation, Palmos validates XPC compatibility:

- A major-version mismatch blocks the operation and requires an update.
- A minor-version mismatch degrades to capabilities supported by both sides.

Deleting the app does not remove the helper automatically. Remove it manually before or after deleting Palmos:

```bash
sudo launchctl bootout system /Library/LaunchDaemons/com.palmos.smartservice.plist
sudo rm /Library/LaunchDaemons/com.palmos.smartservice.plist
sudo rm /Library/PrivilegedHelperTools/com.palmos.smartservice
sudo rm /Library/PrivilegedHelperTools/com.palmos.smartservice.smartctl
```

## Building

Open `Palmos.xcworkspace`, select the `PalmosApp` scheme, and build. Unsigned builds work without SMART. A runnable SMART path requires the app, helper, and companion to use the same Apple Development Team.

After creating an Apple Development identity, build a local SMART-enabled app with:

```bash
Scripts/build-local-smart-app.sh
```

The script rebuilds smartctl 7.5 from the pinned, checksum-verified source archive, signs it, propagates its post-signing SHA-256 into the helper, builds all components with the extracted Team ID, and runs the complete signing verifier. It does not perform destructive cleanup of an already installed helper from another Team.

## Testing

```bash
cd Packages/PalmosCore && swift test

xcodebuild test \
  -workspace Palmos.xcworkspace \
  -scheme PalmosApp \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
```

Pushes to `main` and pull requests always run lightweight release-automation checks. Changes limited to `README.md`, `docs/`, `LICENSE`, or `AGENTS.md` skip the macOS build unless publishing is enabled. All other changes run the Core, App, Helper security, packaging, and unsigned arm64 build checks; `release: true` also forces this full check.

## License

Copyright © 2025–2026 SlippinDylan Studio. Palmos is licensed under the [Apache License 2.0](LICENSE).

### Third-Party Licenses

Palmos bundles [MenuBarExtraAccess 1.3.0](https://github.com/orchetect/MenuBarExtraAccess) under the MIT License and a separately signed `smartctl` built from smartmontools 7.5 under GPL version 2 or later. The complete notices are stored in [`Shared/Licensing`](Shared/Licensing) and included in the app bundle.

The exact corresponding smartmontools source archive is embedded at `Palmos.app/Contents/Resources/ThirdPartySources/smartmontools-7.5.tar.gz`. Its required SHA-256 is `690b83ca331378da9ea0d9d61008c4b22dde391387b9bbad7f29387f2595f76e`.
