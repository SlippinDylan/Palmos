# DrivePulse Manual Smoke Checklist

Run this checklist after each significant change to the app or helper. Every item must pass before a release build is cut.

## Launch

- [ ] App launches from Finder with no Dock icon visible
- [ ] Menu bar icon appears after launch
- [ ] Clicking the menu bar icon opens the popover window

## Device Discovery

- [ ] USB external SSD or HDD appears in the device picker
- [ ] Thunderbolt enclosure appears with correct connection metadata
- [ ] SD card appears in the device picker when inserted
- [ ] Multi-volume device shows all associated volumes
- [ ] Unmounted device still appears in the picker (no mounted volumes, visible entry)
- [ ] Removing a device removes it from the picker
- [ ] Re-inserting a device adds it back with a fresh session

## Throughput

- [ ] Read and write speeds update while data is being transferred
- [ ] Session cumulative counters reset when device is removed and reinserted
- [ ] Throughput chart renders without errors for an active device

## Volumes

- [ ] Volume list shows all volumes for the selected device
- [ ] Mount point and file system are displayed correctly
- [ ] Empty volumes section shows clear empty state when no volumes are mounted

## Actions

- [ ] Open in Finder reveals the first mounted volume in Finder
- [ ] Open Disk Utility launches Disk Utility
- [ ] Safe Eject ejects the selected physical device
- [ ] Settings opens the Settings window

## Settings

- [ ] Launch at Login toggle saves and persists across app restarts
- [ ] Temperature unit toggle updates the displayed temperature in the UI

## SMART — Helper Not Installed

- [ ] Opening SMART section without the helper shows "Helper required" state
- [ ] "Install Helper" button triggers the system credential prompt
- [ ] After install, SMART data refreshes automatically

## SMART — Helper Installed

- [ ] Refresh reads SMART data and shows overall health and temperature
- [ ] Highest temperature is displayed in the Overview card
- [ ] All temperature sensors appear in the SMART detail section

## SMART — Outdated Helper

- [ ] When the installed helper has an older major version, "Update required" state appears
- [ ] Minor version mismatch degrades gracefully without a forced update prompt

## SMART — Helper Removed

- [ ] Manually removing the helper binary causes the next refresh to show "Helper required"
- [ ] Re-installing the helper restores normal SMART operation

## SMART — Unsupported Paths

- [ ] A device that does not support SMART shows "SMART unavailable" (not a crash or blank)
- [ ] A device needing a transport hint but missing one shows "Transport support required"

## Uninstall

- [ ] "Remove Advanced Monitoring" action in Settings removes the helper binary and launchd plist
- [ ] After removal, SMART section shows "Helper required" without crashing
