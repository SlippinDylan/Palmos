import DrivePulseCore

/// Preserves context that is richer than a sparse discovery observation.
///
/// Discovery is allowed to return only the fields currently visible from Disk
/// Arbitration. This merger keeps previously resolved details without letting
/// a sparse event resurrect mounted volumes after an eject unless the
/// controller explicitly identifies the active eject target.
struct DeviceContextMerger {
    func merge(
        incoming devices: [ExternalDevice],
        existing existingDevices: [ExternalDevice],
        preservingMountedVolumesFor ejectingDeviceID: DeviceID?
    ) -> [ExternalDevice] {
        let existingDevicesByID = Dictionary(
            uniqueKeysWithValues: existingDevices.map { ($0.id, $0) }
        )
        return devices.map { incoming in
            guard let existing = existingDevicesByID[incoming.id] else {
                return incoming
            }
            return merge(
                existing: existing,
                incoming: incoming,
                preserveMountedVolumes: ejectingDeviceID == incoming.id
            )
        }
    }

    private func merge(
        existing: ExternalDevice,
        incoming: ExternalDevice,
        preserveMountedVolumes: Bool
    ) -> ExternalDevice {
        var merged = incoming

        if isGenericDisplayName(
            merged.displayName,
            forPhysicalBSDName: merged.physicalStoreBSDName
        ) {
            merged.displayName = existing.displayName
        }
        if shouldPrefer(existing.transportName, over: merged.transportName) {
            merged.transportName = existing.transportName
        }
        if merged.capacityBytes == nil {
            merged.capacityBytes = existing.capacityBytes
        }
        if merged.apfsContainerBSDName == nil {
            merged.apfsContainerBSDName = existing.apfsContainerBSDName
        }
        if merged.volumes.isEmpty, preserveMountedVolumes {
            merged.volumes = existing.volumes
        }
        if merged.nvmeInfo == nil {
            merged.nvmeInfo = existing.nvmeInfo
        }
        if merged.thunderboltInfo == nil {
            merged.thunderboltInfo = existing.thunderboltInfo
        }
        if merged.pciInfo == nil {
            merged.pciInfo = existing.pciInfo
        }
        if merged.apfsContainerDetails == nil {
            merged.apfsContainerDetails = existing.apfsContainerDetails
        }
        if merged.physicalPartitions.isEmpty {
            merged.physicalPartitions = existing.physicalPartitions
        }

        return merged
    }

    private func isGenericDisplayName(
        _ displayName: String,
        forPhysicalBSDName physicalBSDName: String
    ) -> Bool {
        displayName.caseInsensitiveCompare(physicalBSDName) == .orderedSame
    }

    private func shouldPrefer(_ existingTransportName: String, over incomingTransportName: String) -> Bool {
        transportQualityScore(existingTransportName) > transportQualityScore(incomingTransportName)
    }

    private func transportQualityScore(_ transportName: String) -> Int {
        let normalizedTransport = transportName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch normalizedTransport {
        case "thunderbolt":
            return 40
        case "usb4":
            return 30
        case "usb", "usb-c", "sd":
            return 20
        case "external", "":
            return 0
        default:
            if normalizedTransport.hasPrefix("io")
                || normalizedTransport.contains("controller")
                || normalizedTransport.contains("storage") {
                return 0
            }
            return 10
        }
    }
}
