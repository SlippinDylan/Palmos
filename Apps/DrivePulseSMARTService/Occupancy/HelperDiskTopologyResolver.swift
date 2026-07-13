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
    static func media(_ bsdName: String) async throws -> HelperDiskMedia? {
        guard let info = try diskutil(arguments: ["info", "-plist", bsdName]) else { return nil }
        return HelperDiskMedia(
            whole: info["Whole"] as? Bool == true,
            external: info["Internal"] as? Bool == false,
            ejectable: info["Ejectable"] as? Bool == true
        )
    }

    static func topology(_ bsdName: String) async throws -> HelperDiskTopology? {
        guard let list = try diskutil(arguments: ["list", "-plist", bsdName]) else { return nil }
        var names = Set<String>()
        var mounts = Set<String>()
        collectStrings(in: list, key: "DeviceIdentifier", into: &names)
        collectStrings(in: list, key: "MountPoint", into: &mounts)

        if let apfs = try diskutil(arguments: ["apfs", "list", "-plist", bsdName]) {
            collectStrings(in: apfs, key: "DeviceIdentifier", into: &names)
            collectStrings(in: apfs, key: "MountPoint", into: &mounts)
        }
        guard names.contains(bsdName) else { return nil }
        let nodes = Set(names.flatMap { ["/dev/\($0)", "/dev/r\($0)"] })
        return HelperDiskTopology(physicalBSDName: bsdName, deviceNodes: nodes, mountPaths: mounts)
    }

    private static func diskutil(arguments: [String]) throws -> [String: Any]? {
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

    private static func collectStrings(in value: Any, key: String, into result: inout Set<String>) {
        if let dictionary = value as? [String: Any] {
            if let string = dictionary[key] as? String, !string.isEmpty { result.insert(string) }
            for child in dictionary.values { collectStrings(in: child, key: key, into: &result) }
        } else if let array = value as? [Any] {
            for child in array { collectStrings(in: child, key: key, into: &result) }
        }
    }
}
