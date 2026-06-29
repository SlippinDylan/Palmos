# DrivePulse

A macOS menu bar app that monitors connected external physical storage devices and presents device health, connection metadata, capacity, mounted volumes, and real-time throughput in a native menu bar window.

## Requirements

- macOS 15 or later
- Xcode 16 or later (to build from source)

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

The `DrivePulseSMARTService` scheme builds the privileged helper binary. For local development with a free Apple ID, use **Automatically manage signing** in the target settings and select your personal team.

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

DrivePulse bundles `smartctl` from [smartmontools](https://www.smartmontools.org), which is licensed under the GNU General Public License version 2. See [`Shared/Licensing/smartmontools-COPYING.txt`](Shared/Licensing/smartmontools-COPYING.txt) for the full license text.
