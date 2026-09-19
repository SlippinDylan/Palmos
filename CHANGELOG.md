# Changelog

All notable changes to Palmos releases are recorded here.

## [0.4.0] - 2026-09-19

### Changed

- Redesigned Settings as a native preference window with compact Alcove-aligned layout and content-driven height.
- Made the release manifest the single version source for App, Helper, tests, update channel, and release automation.

### Documentation

- Reorganized Agent guidance into a concise repository contract with dedicated architecture and development references.

## [0.3.0-beta.1] - 2026-09-17

### Security

- Enabled Hardened Runtime for the app and privileged SMART Helper.
- Added bidirectional code-signing requirements for App and Helper XPC connections.
- Associated the legacy LaunchDaemon with the Palmos app in macOS background-item management.

### Fixed

- Restored the app framework runpath so release builds can load Sparkle and launch successfully.

### Validation

- Added release checks for Hardened Runtime and the macOS 26 deployment target.
- Added a real arm64 smartctl source build to macOS CI.
- Made the release manifest the single version source and added CI drift checks for generated Xcode settings.

## [0.2.0-beta.1] - 2026-09-17

### Added

- Added Sparkle 2 signed automatic updates with a manual check in Settings.
- Added signed appcast generation and channel-specific Homebrew Cask publishing through the shared personal tap.

### Distribution

- Keeps the privileged SMART Helper and bundled smartctl installation under explicit Palmos authorization rather than Sparkle.
- Rejects appcast and Cask downgrades and retries concurrent shared-tap updates safely.

## [0.1.0-beta.4] - 2026-09-16

### Added

- Added unified CI checks for every branch push and pull request.
- Added manifest-gated publishing, draft Release verification, and Feishu activity notifications.

### Changed

- Reset the product version to `0.1.0-beta.4` and made publishing explicitly opt-in.

### Fixed

- Removed the transient temperature refresh message while preserving the last-reading notice after failures.
