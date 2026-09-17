# Changelog

All notable changes to Palmos releases are recorded here.

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
