import AppKit
import Darwin
import Foundation

struct ProcessOccupancySnapshot: Codable, Equatable, Sendable {
    let pid: Int32
    let executableName: String
    let displayName: String?
    let openPaths: [String]
    let workingDirectory: String?
    let deviceNodes: [String]
}

protocol ProcessInspecting: Sendable {
    func candidatePIDs(limit: Int) throws -> [Int32]
    func inspect(pid: Int32) throws -> ProcessOccupancySnapshot
}

protocol AppOccupancyScanning: Sendable {
    func scan(scope: OccupancyTargetScope, deadline: ContinuousClock.Instant) async -> OccupancyScanResult
}

private protocol CooperativelyProcessInspecting: ProcessInspecting {
    func inspect(
        pid: Int32,
        while shouldContinue: @escaping @Sendable () -> Bool
    ) throws -> ProcessOccupancySnapshot
}

struct AppOccupancyScanner: AppOccupancyScanning {
    private static let candidateLimit = 4_096
    private static let holderLimit = 64

    private let inspector: any ProcessInspecting
    private let clock = ContinuousClock()

    init(inspector: any ProcessInspecting = LiveProcessInspector()) {
        self.inspector = inspector
    }

    func scan(scope: OccupancyTargetScope, deadline: ContinuousClock.Instant) async -> OccupancyScanResult {
        let candidatePIDs: [Int32]
        do {
            candidatePIDs = try inspector.candidatePIDs(limit: Self.candidateLimit)
        } catch {
            return OccupancyScanResult(holders: [], isComplete: false)
        }

        var holders: [OccupancyHolder] = []
        var isComplete = candidatePIDs.count < Self.candidateLimit

        for (index, pid) in candidatePIDs.enumerated() {
            guard shouldContinue(until: deadline) else {
                isComplete = false
                break
            }

            do {
                let snapshot = try inspect(pid: pid, deadline: deadline)
                holders.append(contentsOf: classify(snapshot, in: scope))
                if holders.count >= Self.holderLimit, index < candidatePIDs.index(before: candidatePIDs.endIndex) {
                    isComplete = false
                    break
                }
            } catch {
                isComplete = false
            }
        }

        let normalizedHolders = Array(Set(holders)).sorted(by: Self.holderSort)
        return OccupancyScanResult(
            holders: Array(normalizedHolders.prefix(Self.holderLimit)),
            isComplete: isComplete
        )
    }

    private static func holderSort(_ lhs: OccupancyHolder, _ rhs: OccupancyHolder) -> Bool {
        if lhs.pid != rhs.pid { return lhs.pid < rhs.pid }
        return lhs.type.rawValue < rhs.type.rawValue
    }

    private func inspect(pid: Int32, deadline: ContinuousClock.Instant) throws -> ProcessOccupancySnapshot {
        guard let cooperativeInspector = inspector as? any CooperativelyProcessInspecting else {
            return try inspector.inspect(pid: pid)
        }
        return try cooperativeInspector.inspect(pid: pid) {
            !Task.isCancelled && ContinuousClock.now < deadline
        }
    }

    private func shouldContinue(until deadline: ContinuousClock.Instant) -> Bool {
        !Task.isCancelled && clock.now < deadline
    }

    private func classify(_ snapshot: ProcessOccupancySnapshot, in scope: OccupancyTargetScope) -> [OccupancyHolder] {
        var types: [OccupancyType] = []
        if snapshot.openPaths.contains(where: scope.contains(path:)) {
            types.append(.openFileOrDirectory)
        }
        if snapshot.workingDirectory.map(scope.contains(path:)) == true {
            types.append(.workingDirectory)
        }
        if snapshot.deviceNodes.contains(where: scope.contains(deviceNode:)) {
            types.append(.deviceNode)
        }

        return types.map {
            OccupancyHolder(
                pid: snapshot.pid,
                executableName: snapshot.executableName,
                displayName: snapshot.displayName,
                type: $0
            )
        }
    }
}

struct LiveProcessInspector: CooperativelyProcessInspecting {
    private enum InspectionError: Error {
        case unavailable
        case interrupted
    }

    func candidatePIDs(limit: Int) throws -> [Int32] {
        let boundedLimit = max(0, min(limit, 4_096))
        guard boundedLimit > 0 else { return [] }

        var pids = [Int32](repeating: 0, count: boundedLimit)
        let processCount = pids.withUnsafeMutableBytes {
            proc_listallpids($0.baseAddress, Int32($0.count))
        }
        guard processCount >= 0 else { throw InspectionError.unavailable }
        let count = min(Int(processCount), boundedLimit)
        return pids.prefix(count).filter { $0 > 0 }
    }

    func inspect(pid: Int32) throws -> ProcessOccupancySnapshot {
        try inspect(pid: pid, while: { !Task.isCancelled })
    }

    func inspect(
        pid: Int32,
        while shouldContinue: @escaping @Sendable () -> Bool
    ) throws -> ProcessOccupancySnapshot {
        guard shouldContinue() else { throw InspectionError.interrupted }
        let executableName = try processName(pid: pid)
        let workingDirectory = try workingDirectory(pid: pid)
        let descriptorPaths = try vnodePaths(pid: pid, while: shouldContinue)
        guard shouldContinue() else { throw InspectionError.interrupted }

        return ProcessOccupancySnapshot(
            pid: pid,
            executableName: executableName,
            displayName: NSRunningApplication(processIdentifier: pid)?.localizedName,
            openPaths: descriptorPaths.filter { !$0.hasPrefix("/dev/") },
            workingDirectory: workingDirectory,
            deviceNodes: descriptorPaths.filter { $0.hasPrefix("/dev/") }
        )
    }

    private func processName(pid: Int32) throws -> String {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &path, UInt32(path.count))
        guard length > 0 else { throw InspectionError.unavailable }
        return URL(fileURLWithPath: decodeNullTerminated(path)).lastPathComponent
    }

    private func workingDirectory(pid: Int32) throws -> String? {
        var info = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        let returned = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, $0, Int32(size))
        }
        guard returned == size else { throw InspectionError.unavailable }
        return cString(from: &info.pvi_cdir.vip_path)
    }

    private func vnodePaths(
        pid: Int32,
        while shouldContinue: @escaping @Sendable () -> Bool
    ) throws -> [String] {
        let byteCount = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard byteCount >= 0 else { throw InspectionError.unavailable }
        guard byteCount > 0 else { return [] }

        let descriptorCount = Int(byteCount) / MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: descriptorCount)
        let returned = descriptors.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard returned >= 0 else { throw InspectionError.unavailable }

        var paths: [String] = []
        for descriptor in descriptors.prefix(Int(returned) / MemoryLayout<proc_fdinfo>.stride) {
            guard shouldContinue() else { throw InspectionError.interrupted }
            guard descriptor.proc_fdtype == PROX_FDTYPE_VNODE else { continue }
            if let path = try vnodePath(pid: pid, fd: descriptor.proc_fd) {
                paths.append(path)
            }
        }
        return paths
    }

    private func vnodePath(pid: Int32, fd: Int32) throws -> String? {
        var info = vnode_fdinfowithpath()
        let size = MemoryLayout<vnode_fdinfowithpath>.size
        let returned = withUnsafeMutablePointer(to: &info) {
            proc_pidfdinfo(pid, fd, PROC_PIDFDVNODEPATHINFO, $0, Int32(size))
        }
        guard returned == size else { throw InspectionError.unavailable }
        return cString(from: &info.pvip.vip_path)
    }

    private func decodeNullTerminated(_ bytes: [CChar]) -> String {
        let utf8 = bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: utf8, as: UTF8.self)
    }

    private func cString<T>(from value: inout T) -> String? {
        withUnsafePointer(to: &value) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) {
                guard $0.pointee != 0 else { return nil }
                return String(cString: $0)
            }
        }
    }
}
