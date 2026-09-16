import Foundation

struct HelperOccupancyScope: Equatable, Sendable {
    let deviceNodes: Set<String>
    let mountPaths: Set<String>

    init(deviceNodes: Set<String>, mountPaths: Set<String>) {
        self.deviceNodes = deviceNodes
        self.mountPaths = mountPaths
    }
}

struct HelperDiskTopology: Equatable, Sendable {
    let physicalBSDName: String
    let deviceNodes: Set<String>
    let mountPaths: Set<String>
}

struct HelperDiskTopologyResolver: Sendable {
    typealias Loader = @Sendable (String) async throws -> HelperDiskTopology?
    private let load: Loader

    init(load: @escaping Loader) {
        self.load = load
    }

    func resolve(wholeBSDName: String) async throws -> HelperOccupancyScope {
        try HelperOccupancyRequestValidator.validateBSDName(wholeBSDName)
        guard let topology = try await load(wholeBSDName) else {
            throw HelperOccupancyError.targetUnavailable
        }
        guard topology.physicalBSDName == wholeBSDName,
              topology.deviceNodes.contains("/dev/\(wholeBSDName)") else {
            throw HelperOccupancyError.unsafeTarget
        }
        return HelperOccupancyScope(deviceNodes: topology.deviceNodes, mountPaths: topology.mountPaths)
    }
}

enum LiveHelperDiskTopologySource {
    typealias DiskutilQuery = @Sendable ([String]) throws -> [String: Any]?

    static func topology(
        _ bsdName: String,
        deadline: ContinuousClock.Instant,
        cancellation: HelperOperationCancellation,
        runner: HelperTopologyCommandRunner
    ) async throws -> HelperDiskTopology? {
        guard let list = try await runner.propertyList(
            arguments: ["list", "-plist", bsdName],
            deadline: deadline,
            cancellation: cancellation
        ), let physical = physicalTopology(bsdName: bsdName, list: list) else { return nil }

        var trustedNames = physical.names
        var mounts = physical.mounts
        var containerNames = Set<String>()
        for partitionName in physical.names where partitionName != bsdName {
            guard let info = try await runner.propertyList(
                arguments: ["info", "-plist", partitionName],
                deadline: deadline,
                cancellation: cancellation
            ) else { continue }
            if let container = info["APFSContainerReference"] as? String,
               container.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil {
                containerNames.insert(container)
            }
        }
        for containerName in containerNames {
            guard let apfs = try await runner.propertyList(
                arguments: ["apfs", "list", "-plist", containerName],
                deadline: deadline,
                cancellation: cancellation
            ), let container = exactContainer(named: containerName, in: apfs),
               append(
                container: container,
                named: containerName,
                physicalNames: physical.names,
                trustedNames: &trustedNames,
                mounts: &mounts
               ) else { return nil }
        }
        return makeTopology(bsdName: bsdName, names: trustedNames, mounts: mounts)
    }

    static func topology(
        _ bsdName: String,
        query: DiskutilQuery
    ) async throws -> HelperDiskTopology? {
        guard let list = try query(["list", "-plist", bsdName]) else { return nil }
        guard let physical = physicalTopology(bsdName: bsdName, list: list) else { return nil }
        var trustedNames = physical.names
        var mounts = physical.mounts
        let partitionNames = physical.names.filter { $0 != bsdName }
        var containerNames = Set<String>()
        for partitionName in partitionNames {
            guard let info = try query(["info", "-plist", partitionName]) else { continue }
            if let container = info["APFSContainerReference"] as? String,
               container.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil {
                containerNames.insert(container)
            }
        }

        for containerName in containerNames {
            guard let apfs = try query(["apfs", "list", "-plist", containerName]),
                  let container = exactContainer(named: containerName, in: apfs) else {
                return nil
            }
            guard append(container: container, named: containerName, physicalNames: physical.names, trustedNames: &trustedNames, mounts: &mounts) else { return nil }
        }
        return makeTopology(bsdName: bsdName, names: trustedNames, mounts: mounts)
    }

    private static func exactContainer(named name: String, in plist: [String: Any]) -> [String: Any]? {
        guard let containers = plist["Containers"] as? [[String: Any]] else { return nil }
        return containers.first { $0["ContainerReference"] as? String == name }
    }

    private static func physicalTopology(
        bsdName: String,
        list: [String: Any]
    ) -> (names: Set<String>, mounts: Set<String>)? {
        guard let disks = list["AllDisksAndPartitions"] as? [[String: Any]],
              let physicalDisk = disks.first(where: { $0["DeviceIdentifier"] as? String == bsdName }) else {
            return nil
        }
        var names = Set<String>()
        var mounts = Set<String>()
        collectStrings(in: physicalDisk, key: "DeviceIdentifier", into: &names)
        collectStrings(in: physicalDisk, key: "MountPoint", into: &mounts)
        guard names.contains(bsdName),
              names.allSatisfy({ $0 == bsdName || isPartition($0, of: bsdName) }) else { return nil }
        return (names, mounts)
    }

    private static func append(
        container: [String: Any],
        named containerName: String,
        physicalNames: Set<String>,
        trustedNames: inout Set<String>,
        mounts: inout Set<String>
    ) -> Bool {
        var stores = Set<String>()
        if let physicalStores = container["PhysicalStores"] {
            collectStrings(in: physicalStores, key: "DeviceIdentifier", into: &stores)
        }
        guard stores.isEmpty == false, stores.isSubset(of: physicalNames) else { return false }
        trustedNames.insert(containerName)
        if let volumes = container["Volumes"] as? [[String: Any]] {
            for volume in volumes {
                guard let volumeName = volume["DeviceIdentifier"] as? String,
                      isPartition(volumeName, of: containerName) else { return false }
                trustedNames.insert(volumeName)
                if let mount = volume["MountPoint"] as? String, !mount.isEmpty { mounts.insert(mount) }
            }
        }
        return true
    }

    private static func makeTopology(
        bsdName: String,
        names: Set<String>,
        mounts: Set<String>
    ) -> HelperDiskTopology {
        let nodes = Set(names.flatMap { ["/dev/\($0)", "/dev/r\($0)"] })
        return HelperDiskTopology(physicalBSDName: bsdName, deviceNodes: nodes, mountPaths: mounts)
    }

    private static func isPartition(_ candidate: String, of whole: String) -> Bool {
        let prefix = "\(whole)s"
        guard candidate.hasPrefix(prefix) else { return false }
        let suffix = candidate.dropFirst(prefix.count)
        return suffix.isEmpty == false && suffix.allSatisfy(\.isNumber)
    }

    private static func collectStrings(in value: Any, key: String, into result: inout Set<String>) {
        if let dictionary = value as? [String: Any] {
            if let string = dictionary[key] as? String, !string.isEmpty { result.insert(string) }
            for child in dictionary.values { collectStrings(in: child, key: key, into: &result) }
        } else if let array = value as? [Any] {
            for child in array { collectStrings(in: child, key: key, into: &result) }
        }
    }
}
