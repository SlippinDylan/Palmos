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

    init(load: @escaping Loader = LiveHelperDiskTopologySource.topology) {
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

    static func media(_ bsdName: String) async throws -> HelperDiskMedia? {
        guard let info = try diskutil(["info", "-plist", bsdName]) else { return nil }
        return HelperDiskMedia(
            whole: info["Whole"] as? Bool == true,
            external: info["Internal"] as? Bool == false,
            ejectable: info["Ejectable"] as? Bool == true
        )
    }

    static func topology(_ bsdName: String) async throws -> HelperDiskTopology? {
        try await topology(bsdName, query: diskutil)
    }

    static func topology(
        _ bsdName: String,
        query: DiskutilQuery
    ) async throws -> HelperDiskTopology? {
        guard let list = try query(["list", "-plist", bsdName]) else { return nil }
        guard let disks = list["AllDisksAndPartitions"] as? [[String: Any]],
              let physicalDisk = disks.first(where: { $0["DeviceIdentifier"] as? String == bsdName }) else {
            return nil
        }
        var physicalNames = Set<String>()
        var mounts = Set<String>()
        collectStrings(in: physicalDisk, key: "DeviceIdentifier", into: &physicalNames)
        collectStrings(in: physicalDisk, key: "MountPoint", into: &mounts)
        guard physicalNames.contains(bsdName),
              physicalNames.allSatisfy({ $0 == bsdName || isPartition($0, of: bsdName) }) else {
            return nil
        }

        var trustedNames = physicalNames
        let partitionNames = physicalNames.filter { $0 != bsdName }
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
            var stores = Set<String>()
            collectStrings(in: container["PhysicalStores"] as Any, key: "DeviceIdentifier", into: &stores)
            guard stores.isEmpty == false, stores.isSubset(of: physicalNames) else { return nil }

            trustedNames.insert(containerName)
            if let volumes = container["Volumes"] as? [[String: Any]] {
                for volume in volumes {
                    guard let volumeName = volume["DeviceIdentifier"] as? String,
                          isPartition(volumeName, of: containerName) else {
                        return nil
                    }
                    trustedNames.insert(volumeName)
                    if let mount = volume["MountPoint"] as? String, mount.isEmpty == false {
                        mounts.insert(mount)
                    }
                }
            }
        }

        let nodes = Set(trustedNames.flatMap { ["/dev/\($0)", "/dev/r\($0)"] })
        return HelperDiskTopology(physicalBSDName: bsdName, deviceNodes: nodes, mountPaths: mounts)
    }

    private static func diskutil(_ arguments: [String]) throws -> [String: Any]? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return try PropertyListSerialization.propertyList(
            from: output.fileHandleForReading.readDataToEndOfFile(),
            options: [],
            format: nil
        ) as? [String: Any]
    }

    private static func exactContainer(named name: String, in plist: [String: Any]) -> [String: Any]? {
        guard let containers = plist["Containers"] as? [[String: Any]] else { return nil }
        return containers.first { $0["ContainerReference"] as? String == name }
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
