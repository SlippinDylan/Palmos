# Palmos

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

Palmos uses three targets:

- **PalmosApp** — Menu bar app, UI, device browsing, throughput visualization, settings, launch-at-login, safe eject.
- **PalmosCore** — Shared domain and application logic. No UI or privileged dependency.
- **PalmosSMARTService** — Privileged helper installed via `SMJobBless`, accessed over XPC, restricted to SMART-related operations and installation of Palmos's signed `smartctl` companion.

The app remains fully functional without the privileged helper. SMART capability is a layered, opt-in feature.

## Installing a GitHub Release

Palmos releases use a free Apple Development certificate so the app and its privileged helper can authenticate each other. They are not notarized, so after moving `PalmosApp.app` to `/Applications`, remove the downloaded bundle's quarantine attribute once:

```sh
sudo xattr -rd com.apple.quarantine /Applications/PalmosApp.app
```

The recursive command covers the embedded helper inside the app bundle. Do not copy the helper out or run a separate `xattr` command for it. Open Palmos normally, then install the SMART Helper from Settings when needed.

Removing quarantine only bypasses Gatekeeper's download quarantine check. It does not replace code signing; the release workflow signs both the app and helper with the same Apple Development team.

## Privileged SMART Helper

Palmos installs a privileged helper the first time advanced SMART monitoring is requested. This helper is required for broad Thunderbolt and USB enclosure coverage because Apple's app-sandboxed APIs do not expose SMART telemetry for most external enclosures.

The helper is installed to `/Library/PrivilegedHelperTools/com.palmos.smartservice` and registered as a launchd daemon. The system prompts for administrator credentials during installation. The same workflow installs the bundled companion to `/Library/PrivilegedHelperTools/com.palmos.smartservice.smartctl` only after the helper verifies its fixed code-signing identifier and matching Team ID. The installed file is root-owned and is never loaded from Homebrew or another user-writable command path.

### Helper Versioning

The app validates XPC contract compatibility before each SMART operation:

- **Major version mismatch** — SMART operations are blocked and an update is required.
- **Minor version mismatch** — The app degrades gracefully; SMART features supported by the shared contract remain available.

### Removing the Helper

Deleting the app bundle does **not** remove the privileged helper automatically. The current app does not provide an uninstall action, so remove the helper manually before or after deleting Palmos:

```sh
sudo launchctl bootout system /Library/LaunchDaemons/com.palmos.smartservice.plist
sudo rm /Library/LaunchDaemons/com.palmos.smartservice.plist
sudo rm /Library/PrivilegedHelperTools/com.palmos.smartservice
sudo rm /Library/PrivilegedHelperTools/com.palmos.smartservice.smartctl
```

## Building

Open `Palmos.xcworkspace` in Xcode, select the `PalmosApp` scheme, and build.
An unsigned build can run without SMART, but the privileged SMART path requires a stable
code-signing identity so the App, Helper, and `smartctl` companion can authenticate each
other.

The `PalmosSMARTService` scheme builds the privileged helper binary. The repository
defaults to the maintainer's public Team ID. Xcode can create an Apple Development identity
for a free Personal Team under **Settings → Accounts → Manage Certificates**. No paid Apple
Developer Program membership, Developer ID certificate, or notarization is required for
local use.

Pull request tests explicitly disable signing from the command line. Local compile/test
commands may do the same. Any running build that uses the SMART Helper must instead sign the
App, Helper, and companion with the same free Apple Development team.

The normal Debug build does not download third-party tools. To build a local SMART-enabled
App, use the dedicated entry point after creating the free Apple Development identity:

```sh
Scripts/build-local-smart-app.sh
```

If more than one Apple Development identity is available, list their SHA-1 hashes with
`security find-identity -v -p codesigning`, then select one explicitly:

```sh
Scripts/build-local-smart-app.sh --identity APPLE_DEVELOPMENT_SHA1
```

The script rebuilds smartctl from the pinned, SHA-verified source archive in an isolated
directory on every run. It signs that fresh binary, propagates its post-signing SHA-256 into
the Helper, builds every component with the Team ID extracted from the signed companion, and
runs the full signing verifier. A verified companion is then published under an immutable,
digest-named path in `DerivedData/LocalSMART`; only after every check succeeds does the script
atomically replace the git-ignored `Config/xcconfigs/Local.xcconfig`. Later Xcode **Cmd+R**
builds reuse that exact signed companion and Personal Team, while command-line builds that
explicitly disable signing omit it. The script prints the exact verified `.app` path to launch.

If the selected Personal Team differs from the Team ID of an already installed Helper,
remove the old Helper with the commands in [Removing the Helper](#removing-the-helper)
before installing from the new build. The installed Helper authorizes clients from its
original Team and the local build script deliberately does not perform destructive system
cleanup automatically.

The release workflow performs the equivalent steps in CI and fails closed if the companion,
signature, license, or source archive is missing.

### GitHub Release Signing

The release workflow expects two GitHub Actions secrets:

- `APPLE_DEVELOPMENT_P12_BASE64` — a base64-encoded export of an Apple Development certificate and its private key.
- `APPLE_DEVELOPMENT_P12_PASSWORD` — the export password for that P12 file.

For example, after exporting the certificate as `AppleDevelopment.p12`, copy its encoded content with:

```sh
base64 -i AppleDevelopment.p12 | pbcopy
```

Add that value and the export password under the repository's **Settings → Secrets and variables → Actions**. The workflow derives the Team ID from the certificate, builds smartmontools 7.5 from its pinned source archive, signs the app, helper, and companion with the same identity, and verifies the strict signatures plus both `SMJobBless` signing requirements before packaging. The Team ID is not a secret and is never used as a credential.

Free Apple Development certificates expire periodically. When renewing one, export the replacement certificate and update the two secrets. As long as the Personal Team ID remains the same, the App/Helper requirements do not need to change.

## Testing

```sh
# Core package tests
cd Packages/PalmosCore && swift test

# App target tests
xcodebuild test -workspace Palmos.xcworkspace \
  -scheme PalmosApp \
  -destination 'platform=macOS'
```

## Third-Party Licenses

Palmos release artifacts include a separately signed `smartctl` executable built from
smartmontools 7.5 with its external drive database disabled, so the root helper never reads
configuration or database files from `/usr/local` or Homebrew locations. smartmontools is
distributed under GNU GPL version 2 or later. The exact
upstream license is included at
[`Shared/Licensing/smartmontools-COPYING.txt`](Shared/Licensing/smartmontools-COPYING.txt)
and inside the app bundle. Each GitHub release also attaches the exact, checksum-pinned
`smartmontools-7.5.tar.gz` corresponding source archive used by the build.

The pinned upstream archive is downloaded from SourceForge and must have SHA-256
`690b83ca331378da9ea0d9d61008c4b22dde391387b9bbad7f29387f2595f76e`.
