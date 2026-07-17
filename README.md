# DrivePulse

A macOS menu bar app that monitors connected external physical storage devices and presents device health, connection metadata, capacity, mounted volumes, and real-time throughput in a native menu bar window.

## Requirements

- macOS 15 or later
- Xcode 26.4 or later with the macOS 26 SDK (to build from source)

## Supported Devices

- USB storage devices
- Thunderbolt / USB4 storage devices
- SD card storage devices
- External SSDs and HDDs
- External NVMe enclosures

Network volumes, internal storage, and iPhone / iPad style mounted devices are excluded.

## Architecture

DrivePulse uses three targets:

- **DrivePulseApp** — Menu bar app, UI, device browsing, throughput visualization, settings, launch-at-login, safe eject.
- **DrivePulseCore** — Shared domain and application logic. No UI or privileged dependency.
- **DrivePulseSMARTService** — Privileged helper installed via `SMJobBless`, accessed over XPC, restricted to SMART-related operations.

The app remains fully functional without the privileged helper. SMART capability is a layered, opt-in feature.

## Installing a GitHub Release

DrivePulse releases use a free Apple Development certificate so the app and its privileged helper can authenticate each other. They are not notarized, so after moving `DrivePulseApp.app` to `/Applications`, remove the downloaded bundle's quarantine attribute once:

```sh
sudo xattr -rd com.apple.quarantine /Applications/DrivePulseApp.app
```

The recursive command covers the embedded helper inside the app bundle. Do not copy the helper out or run a separate `xattr` command for it. Open DrivePulse normally, then install the SMART Helper from Settings when needed.

Removing quarantine only bypasses Gatekeeper's download quarantine check. It does not replace code signing; the release workflow signs both the app and helper with the same Apple Development team.

## Privileged SMART Helper

DrivePulse installs a privileged helper the first time advanced SMART monitoring is requested. This helper is required for broad Thunderbolt and USB enclosure coverage because Apple's app-sandboxed APIs do not expose SMART telemetry for most external enclosures.

The helper is installed to `/Library/PrivilegedHelperTools/com.drivepulse.smartservice` and registered as a launchd daemon. The system prompts for administrator credentials during installation.

### Helper Versioning

The app validates XPC contract compatibility before each SMART operation:

- **Major version mismatch** — SMART operations are blocked and an update is required.
- **Minor version mismatch** — The app degrades gracefully; SMART features supported by the shared contract remain available.

### Removing the Helper

Deleting the app bundle does **not** remove the privileged helper automatically. Before deleting DrivePulse, use the in-app **Remove Advanced Monitoring** action in Settings to uninstall the helper cleanly.

If the app has already been deleted, remove the helper manually:

```sh
sudo launchctl unload /Library/LaunchDaemons/com.drivepulse.smartservice.plist
sudo rm /Library/LaunchDaemons/com.drivepulse.smartservice.plist
sudo rm /Library/PrivilegedHelperTools/com.drivepulse.smartservice
```

## Building

Open `DrivePulse.xcworkspace` in Xcode, select the `DrivePulseApp` scheme, and build.

The `DrivePulseSMARTService` scheme builds the privileged helper binary. The repository defaults to the maintainer's public Team ID. For a fork or local development with another free Apple ID, replace `DEVELOPMENT_TEAM` in `Config/xcconfigs/Base.xcconfig` with your Personal Team ID. Both targets inherit that value so their signing requirements remain compatible. No paid Developer ID certificate or notarization is required for local use.

Pull request tests explicitly disable signing from the command line. Any build that needs to install the SMART Helper must keep signing enabled and use the same Apple Development team for both targets.

### GitHub Release Signing

The release workflow expects two GitHub Actions secrets:

- `APPLE_DEVELOPMENT_P12_BASE64` — a base64-encoded export of an Apple Development certificate and its private key.
- `APPLE_DEVELOPMENT_P12_PASSWORD` — the export password for that P12 file.

For example, after exporting the certificate as `AppleDevelopment.p12`, copy its encoded content with:

```sh
base64 -i AppleDevelopment.p12 | pbcopy
```

Add that value and the export password under the repository's **Settings → Secrets and variables → Actions**. The workflow derives the Team ID from the certificate, signs the app and helper with the same identity, and verifies the strict signatures plus both `SMJobBless` signing requirements before packaging. The Team ID is not a secret and is never used as a credential.

Free Apple Development certificates expire periodically. When renewing one, export the replacement certificate and update the two secrets. As long as the Personal Team ID remains the same, the App/Helper requirements do not need to change.

## Testing

```sh
# Core package tests
cd Packages/DrivePulseCore && swift test

# App target tests
xcodebuild test -workspace DrivePulse.xcworkspace \
  -scheme DrivePulseApp \
  -destination 'platform=macOS'
```

## Third-Party Licenses

The current source tree does not bundle `smartctl`. The privileged helper only accepts a
root-owned companion at `/Library/PrivilegedHelperTools/com.drivepulse.smartservice.smartctl`;
it never searches Homebrew or other user-writable locations. Until a release artifact has
installed and verified that companion, SMART is reported as unavailable. A release that ships
the companion must include the exact smartmontools license text and update packaging
verification before claiming bundled SMART support.

See [`Shared/Licensing/smartmontools-COPYING.txt`](Shared/Licensing/smartmontools-COPYING.txt)
for the repository's current licensing status.
