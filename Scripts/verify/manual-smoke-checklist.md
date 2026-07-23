# Palmos Manual Smoke Checklist

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

## Panel Presentation

- [ ] At the 360-point panel width, header, device picker, content, and footer share one continuous window background in English, Simplified Chinese, and Traditional Chinese
- [ ] Section separators span the panel with matching left and right insets
- [ ] Capacity usage renders as an outlined segmented bar with accurate Used and Available values in Light and Dark appearances

## Volumes

- [ ] Volume list shows all volumes for the selected device
- [ ] Mount point and file system are displayed correctly
- [ ] Empty volumes section shows clear empty state when no volumes are mounted

## Actions

- [ ] Open in Finder reveals the first mounted volume in Finder
- [ ] Open Disk Utility launches Disk Utility
- [ ] Safe Eject ejects the selected physical device
- [ ] Settings opens the Settings window

## Safe Eject and Occupancy Diagnostics

> **Disposable-media requirement:** perform these checks only with an external disk that contains no valuable data. Stop all real backups and copies first. Never use the fixture script to justify force ejecting valuable media.

- [ ] Run `Scripts/verify/safe-eject-fixture.sh check --device diskN` and confirm the selected whole disk and mounted descendants are correct
- [ ] Normal eject uses whole-disk unmount followed by eject and reports “safe to remove” only after eject succeeds
- [ ] Open-file holder is identified after running the fixture's `open-file-holder` command on the disposable mounted volume
- [ ] Working-directory holder is identified after running `working-directory-holder`
- [ ] Device-node holder is identified when current permissions allow `device-node-holder`
- [ ] When holder inspection is unavailable or empty, UI honestly says macOS reports the disk in use but the process could not be identified
- [ ] Busy recovery remains visible until Cancel, Retry Eject, or Force Eject… is selected
- [ ] Retry keeps the recovery explanation visible while the normal eject operation is running
- [ ] Force Eject… opens a second confirmation; Cancel is the safe/default action and Force Eject is destructive
- [ ] Confirmed force-unmount failure reports the force-unmount stage and never reports safe removal
- [ ] Forced-unmount success followed by eject failure reports the eject stage and never reports safe removal
- [ ] Releasing holders with `release-holders` allows a subsequent normal eject
- [ ] Palmos is not reported as its own occupying process while SMART/capacity enrichment is draining
- [ ] APFS media with multiple volumes includes every mounted descendant in occupancy matching
- [ ] Non-APFS partitioned media matches exact mounted descendants without path-prefix collisions
- [ ] Removing/reassigning the target during recovery prevents Retry or Force from acting on the replacement disk
- [ ] Validate on both Apple silicon and Intel hardware when preparing a universal release
- [ ] Validate every supported macOS major version
- [ ] At the 360-point panel width, verify English, Simplified Chinese, and Traditional Chinese layouts without clipped recovery or confirmation controls

## Settings

- [ ] Launch at Login toggle saves and persists across app restarts
- [ ] Temperature unit toggle updates the displayed temperature in the UI

## SMART — Helper Not Installed

- [ ] Verify the release bundle with `Scripts/verify/code-signing.sh /path/to/PalmosApp.app <TEAM_ID>` before packaging
- [ ] Confirm the release bundle contains `Contents/Library/Helpers/com.palmos.smartservice.smartctl` and the bundled Palmos, MenuBarExtraAccess, and smartmontools license files
- [ ] After copying a downloaded build to `/Applications`, run `sudo xattr -rd com.apple.quarantine /Applications/PalmosApp.app` once; do not extract or separately modify the embedded helper
- [ ] Opening SMART section without the helper shows "Helper required" state
- [ ] "Install Helper" button triggers the system credential prompt
- [ ] After install, SMART data refreshes automatically
- [ ] The installed helper and launchd plist exist only after the signed preflight and administrator authorization succeed
- [ ] The installed companion exists at `/Library/PrivilegedHelperTools/com.palmos.smartservice.smartctl`, is owned by root, is not group/world writable, and matches the release Team ID

## SMART — Helper Installed

- [ ] Refresh reads SMART data and shows overall health and temperature
- [ ] Refresh SMART Data is a centered compact glass capsule on macOS 26 and a centered bordered capsule on earlier supported macOS versions
- [ ] Replacing the bundled companion with an unsigned or differently signed executable causes installation to fail without replacing an existing trusted companion
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

- [ ] Manual helper removal with `launchctl bootout system` removes the launchd job, helper binary, and plist
- [ ] After removal, SMART section shows "Helper required" without crashing
