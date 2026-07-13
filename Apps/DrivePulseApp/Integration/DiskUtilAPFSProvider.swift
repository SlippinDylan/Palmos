import Foundation

import DrivePulseCore

// MARK: - Protocol

protocol DiskUtilAPFSProviding: AnyObject, Sendable {
    func refresh() async
    func refresh(physicalBSDNames: Set<String>) async
    func refresh(targets: [APFSTopologyTarget]) async
    func containerInfo(forContainerBSDName bsdName: String) async -> APFSContainerInfo?
    func physicalPartitions(forDiskBSDName bsdName: String) async -> [PhysicalPartitionInfo]
}

extension DiskUtilAPFSProviding {
    func refresh(physicalBSDNames: Set<String>) async { await refresh() }
    func refresh(targets: [APFSTopologyTarget]) async {
        await refresh(physicalBSDNames: Set(targets.map(\.physicalBSDName)))
    }
}

struct APFSTopologyTarget: Equatable, Sendable {
    let physicalBSDName: String
    let containerBSDName: String?
}

// MARK: - Live Implementation

final class LiveDiskUtilAPFSProvider: DiskUtilAPFSProviding, @unchecked Sendable {
    private let cacheBox = DiskUtilAPFSCacheBox()
    private let requestCoordinator = LatestRequestCoordinator()
    private let commandRunner: @Sendable (String, [String]) async -> Data?
    private let deviceIOTracker: DeviceIOTracker?
    private let physicalBSDNameResolver: @Sendable (String) -> String?

    func usesDeviceIOTracker(_ tracker: DeviceIOTracker) -> Bool {
        deviceIOTracker === tracker
    }

    init(
        commandRunner: @escaping @Sendable (String, [String]) async -> Data? = LiveDiskUtilAPFSProvider.runSubprocess,
        deviceIOTracker: DeviceIOTracker? = nil,
        physicalBSDNameResolver: @escaping @Sendable (String) -> String? = LiveDiskUtilAPFSProvider.defaultPhysicalBSDName
    ) {
        self.commandRunner = commandRunner
        self.deviceIOTracker = deviceIOTracker
        self.physicalBSDNameResolver = physicalBSDNameResolver
    }

    func refresh() async {
        await refresh(physicalBSDNames: [])
    }

    func refresh(physicalBSDNames: Set<String>) async {
        await refresh(targets: physicalBSDNames.map {
            APFSTopologyTarget(physicalBSDName: $0, containerBSDName: nil)
        })
    }

    func refresh(targets: [APFSTopologyTarget]) async {
        let generation = await requestCoordinator.beginRequest()
        guard let containerInfoByBSDName = await fetchContainerInfoByBSDName(
            targets: targets
        ) else {
            return
        }

        guard await requestCoordinator.isLatest(generation) else { return }
        cacheBox.set(containerInfoByBSDName)
    }

    func containerInfo(forContainerBSDName bsdName: String) async -> APFSContainerInfo? {
        let containerInfoByBSDName = await cachedContainerInfoByBSDName(
            requestedBSDName: bsdName
        )
        return containerInfoByBSDName?[bsdName]
    }

    func physicalPartitions(forDiskBSDName bsdName: String) async -> [PhysicalPartitionInfo] {
        guard let data = await runTargetCommand(
            physicalBSDName: bsdName,
            arguments: ["list", "-plist", bsdName]
        ) else {
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

    private func cachedContainerInfoByBSDName(
        requestedBSDName: String
    ) async -> [String: APFSContainerInfo]? {
        if let cached = cacheBox.get() {
            return cached
        }

        let generation = await requestCoordinator.beginRequest()
        guard let physicalBSDName = physicalBSDNameResolver(requestedBSDName) else {
            return nil
        }
        guard let containerInfoByBSDName = await fetchContainerInfoByBSDName(
            targets: [APFSTopologyTarget(
                physicalBSDName: physicalBSDName,
                containerBSDName: requestedBSDName
            )]
        ) else {
            return nil
        }

        guard await requestCoordinator.isLatest(generation) else {
            return cacheBox.get()
        }
        cacheBox.setIfNil(containerInfoByBSDName)
        return cacheBox.get()
    }

    private func fetchContainerInfoByBSDName(
        targets: [APFSTopologyTarget]
    ) async -> [String: APFSContainerInfo]? {
        guard targets.isEmpty == false else {
            return nil
        }

        var containerInfoByBSDName: [String: APFSContainerInfo] = [:]
        let orderedTargets = targets.sorted {
            $0.physicalBSDName.localizedStandardCompare($1.physicalBSDName) == .orderedAscending
        }
        for target in orderedTargets {
            guard let data = await runAPFSListCommand(target: target) else {
                continue
            }
            guard let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
            ) as? [String: Any] else {
                NSLog("[DiskUtilAPFSProvider] Failed to parse scoped diskutil apfs list plist")
                continue
            }
            let containers = plist["Containers"] as? [[String: Any]] ?? []
            for container in containers {
                guard let bsdName = container["ContainerReference"] as? String,
                      bsdName.isEmpty == false,
                      containerInfoByBSDName[bsdName] == nil else {
                    continue
                }
                containerInfoByBSDName[bsdName] = await buildContainerInfo(
                    from: container,
                    bsdName: bsdName
                )
            }
        }
        return containerInfoByBSDName
    }

    private func buildContainerInfo(from container: [String: Any], bsdName: String) async -> APFSContainerInfo {
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
            var parsedVolumes: [APFSVolumeDetails] = []
            parsedVolumes.reserveCapacity(rawVolumes.count)
            for rawVolume in rawVolumes {
                parsedVolumes.append(await buildVolumeDetails(from: rawVolume))
            }
            volumes = parsedVolumes
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

    private func buildVolumeDetails(from volume: [String: Any]) async -> APFSVolumeDetails {
        var details = buildBaseVolumeDetails(from: volume)
        guard needsDiskInfoFallback(for: details) else {
            return details
        }

        guard let supplementalDetails = await fetchSupplementalVolumeDetails(
            forBSDName: details.bsdName
        ) else {
            return details
        }

        details = mergeVolumeDetails(details, with: supplementalDetails)
        return details
    }

    private func buildBaseVolumeDetails(from volume: [String: Any]) -> APFSVolumeDetails {
        let volumeName = (volume["Name"] as? String) ?? (volume["VolumeName"] as? String) ?? ""
        let bsdName = (volume["DeviceIdentifier"] as? String) ?? ""
        let mountPoint = volume["MountPoint"] as? String
        let sealed = parseSealed(from: volume["Sealed"])

        let capacityConsumed = ((volume["CapacityConsumed"] as? NSNumber)?.int64Value)
            ?? ((volume["CapacityInUse"] as? NSNumber)?.int64Value)
        let fileVaultEnabled = volume["FileVault"] as? Bool

        let writable = volume["Writable"] as? Bool
        let ignoreOwnership = volume["IgnoreOwnership"] as? Bool
        let volumeUUID = (volume["VolumeUUID"] as? String) ?? (volume["APFSVolumeUUID"] as? String)

        return APFSVolumeDetails(
            volumeName: volumeName,
            bsdName: bsdName,
            mountPoint: mountPoint,
            fileSystem: "APFS",
            caseSensitive: nil,
            role: parseRole(from: volume),
            capacityConsumedBytes: capacityConsumed,
            fileVaultEnabled: fileVaultEnabled,
            sealed: sealed,
            writable: writable,
            ignoreOwnership: ignoreOwnership,
            volumeUUID: volumeUUID,
            logicalBlockSize: nil,
            isVolumeDetailComplete: bsdName.isEmpty || sealed != nil
        )
    }

    private func needsDiskInfoFallback(for volume: APFSVolumeDetails) -> Bool {
        volume.bsdName.isEmpty == false && volume.sealed == nil
    }

    private func fetchSupplementalVolumeDetails(forBSDName bsdName: String) async -> APFSVolumeDetails? {
        guard let physicalBSDName = physicalBSDNameResolver(bsdName),
              let data = await runTargetCommand(
                physicalBSDName: physicalBSDName,
                arguments: ["info", "-plist", "/dev/\(bsdName)"]
              ) else {
            NSLog("[DiskUtilAPFSProvider] diskutil info returned no data for %@", bsdName)
            return nil
        }

        guard let plist = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any] else {
            NSLog("[DiskUtilAPFSProvider] Failed to parse diskutil info plist for %@", bsdName)
            return nil
        }

        return APFSVolumeDetails(
            volumeName: (plist["VolumeName"] as? String) ?? (plist["MediaName"] as? String) ?? "",
            bsdName: (plist["DeviceIdentifier"] as? String) ?? bsdName,
            mountPoint: plist["MountPoint"] as? String,
            fileSystem: (plist["FilesystemUserVisibleName"] as? String)
                ?? (plist["FilesystemName"] as? String),
            caseSensitive: nil,
            role: parseRole(from: plist),
            capacityConsumedBytes: (plist["CapacityInUse"] as? NSNumber)?.int64Value,
            fileVaultEnabled: plist["FileVault"] as? Bool,
            sealed: parseSealed(from: plist["Sealed"]),
            writable: (plist["WritableVolume"] as? Bool) ?? (plist["Writable"] as? Bool),
            ignoreOwnership: plist["IgnoreOwnership"] as? Bool,
            volumeUUID: (plist["VolumeUUID"] as? String) ?? (plist["DiskUUID"] as? String),
            logicalBlockSize: (plist["VolumeAllocationBlockSize"] as? NSNumber)?.intValue,
            isVolumeDetailComplete: parseSealed(from: plist["Sealed"]) != nil
        )
    }

    private func mergeVolumeDetails(
        _ base: APFSVolumeDetails,
        with supplemental: APFSVolumeDetails
    ) -> APFSVolumeDetails {
        APFSVolumeDetails(
            volumeName: base.volumeName.isEmpty ? supplemental.volumeName : base.volumeName,
            bsdName: base.bsdName.isEmpty ? supplemental.bsdName : base.bsdName,
            mountPoint: base.mountPoint ?? supplemental.mountPoint,
            fileSystem: base.fileSystem ?? supplemental.fileSystem,
            caseSensitive: base.caseSensitive ?? supplemental.caseSensitive,
            role: base.role ?? supplemental.role,
            capacityConsumedBytes: base.capacityConsumedBytes ?? supplemental.capacityConsumedBytes,
            fileVaultEnabled: base.fileVaultEnabled ?? supplemental.fileVaultEnabled,
            sealed: base.sealed ?? supplemental.sealed,
            writable: base.writable ?? supplemental.writable,
            ignoreOwnership: base.ignoreOwnership ?? supplemental.ignoreOwnership,
            volumeUUID: base.volumeUUID ?? supplemental.volumeUUID,
            logicalBlockSize: base.logicalBlockSize ?? supplemental.logicalBlockSize,
            isVolumeDetailComplete: (base.sealed ?? supplemental.sealed) != nil
        )
    }

    private func parseRole(from volume: [String: Any]) -> String? {
        if let roles = volume["Roles"] as? [String], let firstRole = roles.first, firstRole.isEmpty == false {
            return firstRole
        }

        let directRoleKeys = ["Role", "APFSRole", "APFSVolumeRole"]
        for key in directRoleKeys {
            if let role = volume[key] as? String, role.isEmpty == false {
                return role
            }
        }

        return nil
    }

    private func parseSealed(from value: Any?) -> Bool? {
        if let value = value as? Bool {
            return value
        }

        if let value = value as? String {
            switch value.lowercased() {
            case "yes":
                return true
            case "no":
                return false
            default:
                return nil
            }
        }

        return nil
    }

    private static func runSubprocess(executable: String, arguments: [String]) async -> Data? {
        await SubprocessRunner.run(executable: executable, arguments: arguments)
    }

    private func runTargetCommand(physicalBSDName: String, arguments: [String]) async -> Data? {
        let token: DeviceIOTracker.Token?
        do {
            token = try await deviceIOTracker?.beginTargetOperation(
                physicalBSDName: physicalBSDName,
                kind: .diskutil
            )
        } catch {
            return nil
        }
        let data = await commandRunner("/usr/sbin/diskutil", arguments)
        if let token, let deviceIOTracker { await deviceIOTracker.finish(token) }
        return data
    }

    private func runAPFSListCommand(target: APFSTopologyTarget) async -> Data? {
        let token: DeviceIOTracker.Token?
        do {
            token = try await deviceIOTracker?.beginTargetOperation(
                physicalBSDName: target.physicalBSDName,
                kind: .diskutil
            )
        } catch {
            return nil
        }

        let containerBSDName: String?
        if let authoritativeContainer = target.containerBSDName {
            containerBSDName = authoritativeContainer
        } else {
            containerBSDName = await resolveContainerBSDName(
                forPhysicalBSDName: target.physicalBSDName
            )
        }
        guard let containerBSDName else {
            if let token, let deviceIOTracker { await deviceIOTracker.finish(token) }
            return nil
        }
        let data = await commandRunner(
            "/usr/sbin/diskutil",
            ["apfs", "list", "-plist", containerBSDName]
        )
        if let token, let deviceIOTracker { await deviceIOTracker.finish(token) }
        return data
    }

    private func resolveContainerBSDName(forPhysicalBSDName physicalBSDName: String) async -> String? {
        guard let data = await commandRunner(
            "/usr/sbin/diskutil",
            ["info", "-plist", physicalBSDName]
        ), let plist = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any],
        plist["DeviceIdentifier"] as? String == physicalBSDName,
        plist["Content"] as? String == "Apple_APFS",
        let containerBSDName = plist["APFSContainerReference"] as? String,
        containerBSDName.range(of: #"^disk\d+$"#, options: .regularExpression) != nil else {
            return nil
        }
        return containerBSDName
    }

    private static func defaultPhysicalBSDName(for bsdName: String) -> String? {
        guard let match = bsdName.range(of: #"^disk\d+"#, options: .regularExpression) else {
            return nil
        }
        return String(bsdName[match])
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
