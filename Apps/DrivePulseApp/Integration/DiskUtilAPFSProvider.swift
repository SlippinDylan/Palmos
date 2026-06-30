import Foundation

import DrivePulseCore

// MARK: - Protocol

protocol DiskUtilAPFSProviding: AnyObject, Sendable {
    func refresh() async
    func containerInfo(forContainerBSDName bsdName: String) async -> APFSContainerInfo?
    func physicalPartitions(forDiskBSDName bsdName: String) async -> [PhysicalPartitionInfo]
}

// MARK: - Live Implementation

final class LiveDiskUtilAPFSProvider: DiskUtilAPFSProviding, @unchecked Sendable {
    private let cacheBox = DiskUtilAPFSCacheBox()
    private let requestCoordinator = LatestRequestCoordinator()
    private let commandRunner: @Sendable (String, [String]) async -> Data?

    init(
        commandRunner: @escaping @Sendable (String, [String]) async -> Data? = LiveDiskUtilAPFSProvider.runSubprocess
    ) {
        self.commandRunner = commandRunner
    }

    func refresh() async {
        let generation = await requestCoordinator.beginRequest()
        guard let containerInfoByBSDName = await fetchContainerInfoByBSDName() else {
            return
        }

        guard await requestCoordinator.isLatest(generation) else { return }
        cacheBox.set(containerInfoByBSDName)
    }

    func containerInfo(forContainerBSDName bsdName: String) async -> APFSContainerInfo? {
        let containerInfoByBSDName = await cachedContainerInfoByBSDName()
        return containerInfoByBSDName?[bsdName]
    }

    func physicalPartitions(forDiskBSDName bsdName: String) async -> [PhysicalPartitionInfo] {
        guard let data = await commandRunner("/usr/sbin/diskutil", ["list", "-plist", bsdName]) else {
            NSLog("[DiskUtilAPFSProvider] diskutil list returned no data for %@", bsdName)
            return []
        }

        guard let plist = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any] else {
            NSLog("[DiskUtilAPFSProvider] Failed to parse diskutil list plist for %@", bsdName)
            return []
        }

        guard let allDisks = plist["AllDisksAndPartitions"] as? [[String: Any]] else {
            return []
        }

        guard let diskEntry = allDisks.first(where: {
            ($0["DeviceIdentifier"] as? String) == bsdName
        }) else {
            return []
        }

        guard let partitions = diskEntry["Partitions"] as? [[String: Any]] else {
            return []
        }

        return partitions
            .compactMap { partition -> PhysicalPartitionInfo? in
                guard let partitionBSDName = partition["DeviceIdentifier"] as? String,
                      !partitionBSDName.isEmpty else { return nil }
                return PhysicalPartitionInfo(
                    bsdName: partitionBSDName,
                    partitionType: partition["Content"] as? String,
                    name: partition["VolumeName"] as? String,
                    sizeBytes: (partition["Size"] as? NSNumber)?.int64Value
                )
            }
            .sorted { $0.bsdName.localizedStandardCompare($1.bsdName) == .orderedAscending }
    }

    // MARK: - Private helpers

    private func cachedContainerInfoByBSDName() async -> [String: APFSContainerInfo]? {
        if let cached = cacheBox.get() {
            return cached
        }

        let generation = await requestCoordinator.beginRequest()
        guard let containerInfoByBSDName = await fetchContainerInfoByBSDName() else {
            return nil
        }

        guard await requestCoordinator.isLatest(generation) else {
            return cacheBox.get()
        }
        cacheBox.setIfNil(containerInfoByBSDName)
        return cacheBox.get()
    }

    private func fetchContainerInfoByBSDName() async -> [String: APFSContainerInfo]? {
        guard let data = await commandRunner(
            "/usr/sbin/diskutil",
            ["apfs", "list", "-plist"]
        ) else {
            NSLog("[DiskUtilAPFSProvider] diskutil apfs list returned no data")
            return nil
        }

        guard let plist = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any] else {
            NSLog("[DiskUtilAPFSProvider] Failed to parse diskutil apfs list plist")
            return nil
        }

        guard let containers = plist["Containers"] as? [[String: Any]] else {
            return [:]
        }

        var containerInfoByBSDName: [String: APFSContainerInfo] = [:]
        for container in containers {
            guard let bsdName = container["ContainerReference"] as? String,
                  bsdName.isEmpty == false else {
                continue
            }
            containerInfoByBSDName[bsdName] = buildContainerInfo(from: container, bsdName: bsdName)
        }
        return containerInfoByBSDName
    }

    private func buildContainerInfo(from container: [String: Any], bsdName: String) -> APFSContainerInfo {
        let physicalStoreBSDName = container["DesignatedPhysicalStore"] as? String
        let containerUUID = container["APFSContainerUUID"] as? String

        let physicalStoreUUID: String?
        if let stores = container["PhysicalStores"] as? [[String: Any]], let first = stores.first {
            physicalStoreUUID = first["DiskUUID"] as? String
        } else {
            physicalStoreUUID = nil
        }

        let totalBytes = (container["CapacityCeiling"] as? NSNumber)?.int64Value
        let freeBytes = (container["CapacityFree"] as? NSNumber)?.int64Value

        let capacityInUse: Int64?
        if let total = totalBytes, let free = freeBytes {
            capacityInUse = total - free
        } else {
            capacityInUse = nil
        }

        let volumes: [APFSVolumeDetails]
        if let rawVolumes = container["Volumes"] as? [[String: Any]] {
            volumes = rawVolumes.map { buildVolumeDetails(from: $0) }
        } else {
            volumes = []
        }

        return APFSContainerInfo(
            bsdName: bsdName,
            physicalStoreBSDName: physicalStoreBSDName,
            containerUUID: containerUUID,
            physicalStoreUUID: physicalStoreUUID,
            totalCapacityBytes: totalBytes,
            capacityInUseBytes: capacityInUse,
            capacityNotAllocatedBytes: freeBytes,
            volumes: volumes
        )
    }

    private func buildVolumeDetails(from volume: [String: Any]) -> APFSVolumeDetails {
        let volumeName = (volume["Name"] as? String) ?? (volume["VolumeName"] as? String) ?? ""
        let bsdName = (volume["DeviceIdentifier"] as? String) ?? ""
        let mountPoint = volume["MountPoint"] as? String

        let role: String?
        if let roles = volume["Roles"] as? [String], !roles.isEmpty {
            role = roles.first
        } else {
            role = nil
        }

        let capacityConsumed = (volume["CapacityConsumed"] as? NSNumber)?.int64Value
        let fileVaultEnabled = volume["FileVault"] as? Bool

        let sealed: Bool?
        if let b = volume["Sealed"] as? Bool {
            sealed = b
        } else if let s = volume["Sealed"] as? String {
            sealed = s == "Yes"
        } else {
            sealed = nil
        }

        let writable = volume["Writable"] as? Bool
        let ignoreOwnership = volume["IgnoreOwnership"] as? Bool
        let volumeUUID = volume["VolumeUUID"] as? String

        return APFSVolumeDetails(
            volumeName: volumeName,
            bsdName: bsdName,
            mountPoint: mountPoint,
            fileSystem: "APFS",
            caseSensitive: nil,
            role: role,
            capacityConsumedBytes: capacityConsumed,
            fileVaultEnabled: fileVaultEnabled,
            sealed: sealed,
            writable: writable,
            ignoreOwnership: ignoreOwnership,
            volumeUUID: volumeUUID,
            logicalBlockSize: nil
        )
    }

    private static func runSubprocess(executable: String, arguments: [String]) async -> Data? {
        await SubprocessRunner.run(executable: executable, arguments: arguments)
    }
}

private final class DiskUtilAPFSCacheBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [String: APFSContainerInfo]?

    func get() -> [String: APFSContainerInfo]? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func setIfNil(_ newValue: [String: APFSContainerInfo]) {
        lock.lock()
        defer { lock.unlock() }
        if value == nil { value = newValue }
    }

    func set(_ newValue: [String: APFSContainerInfo]) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }
}
