import DrivePulseCore

/// Adds APFS container and physical-partition details without owning UI state.
struct APFSDeviceEnricher {
    func enrich(
        _ devices: [ExternalDevice],
        using provider: any DiskUtilAPFSProviding
    ) async -> [ExternalDevice] {
        var result = devices
        for index in result.indices {
            var device = result[index]
            if let containerBSDName = device.apfsContainerBSDName {
                let containerDetails = await provider.containerInfo(
                    forContainerBSDName: containerBSDName
                )
                device.apfsContainerDetails = Self.mergeMountedVolumeMetadata(
                    into: containerDetails,
                    mountedVolumes: device.volumes
                )
            }
            if device.physicalPartitions.isEmpty {
                device.physicalPartitions = await provider.physicalPartitions(
                    forDiskBSDName: device.physicalStoreBSDName
                )
            }
            result[index] = device
        }
        return result
    }

    private static func mergeMountedVolumeMetadata(
        into containerDetails: APFSContainerInfo?,
        mountedVolumes: [MountedVolume]
    ) -> APFSContainerInfo? {
        guard var containerDetails else {
            return nil
        }

        let mountPointsByBSDName: [String: String] = Dictionary(
            uniqueKeysWithValues: mountedVolumes.compactMap { volume in
                guard let mountPoint = volume.mountPoint, mountPoint.isEmpty == false else {
                    return nil
                }
                return (volume.bsdName, mountPoint)
            }
        )
        guard mountPointsByBSDName.isEmpty == false else {
            return containerDetails
        }

        for index in containerDetails.volumes.indices {
            let bsdName = containerDetails.volumes[index].bsdName
            if containerDetails.volumes[index].mountPoint == nil {
                containerDetails.volumes[index].mountPoint = mountPointsByBSDName[bsdName]
            }
        }
        return containerDetails
    }
}
