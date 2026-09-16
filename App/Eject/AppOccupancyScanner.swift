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
    let isComplete: Bool

    init(
        pid: Int32,
        executableName: String,
        displayName: String?,
        openPaths: [String],
        workingDirectory: String?,
        deviceNodes: [String],
        isComplete: Bool = true
    ) {
        self.pid = pid
        self.executableName = executableName
        self.displayName = displayName
        self.openPaths = openPaths
        self.workingDirectory = workingDirectory
        self.deviceNodes = deviceNodes
        self.isComplete = isComplete
    }

    private enum CodingKeys: String, CodingKey {
        case pid, executableName, displayName, openPaths, workingDirectory, deviceNodes, isComplete
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pid = try container.decode(Int32.self, forKey: .pid)
        executableName = try container.decode(String.self, forKey: .executableName)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        openPaths = try container.decode([String].self, forKey: .openPaths)
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
        deviceNodes = try container.decode([String].self, forKey: .deviceNodes)
        isComplete = try container.decodeIfPresent(Bool.self, forKey: .isComplete) ?? true
    }
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
    init(inspector: any ProcessInspecting = LiveProcessInspector()) {
        self.inspector = inspector
    }

    func scan(scope: OccupancyTargetScope, deadline: ContinuousClock.Instant) async -> OccupancyScanResult {
        let cancellation = ScanCancellation()
        return await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                scanSynchronously(scope: scope, deadline: deadline, cancellation: cancellation)
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func scanSynchronously(
        scope: OccupancyTargetScope,
        deadline: ContinuousClock.Instant,
        cancellation: ScanCancellation
    ) -> OccupancyScanResult {
        let candidatePIDs: [Int32]
        do {
            candidatePIDs = try inspector.candidatePIDs(limit: Self.candidateLimit)
        } catch {
            return OccupancyScanResult(holders: [], isComplete: false)
        }

        var holders: [OccupancyHolder] = []
        var isComplete = candidatePIDs.count < Self.candidateLimit

        for (index, pid) in candidatePIDs.enumerated() {
            guard shouldContinue(until: deadline, cancellation: cancellation) else {
                isComplete = false
                break
            }

            do {
                let snapshot = try inspect(pid: pid, deadline: deadline, cancellation: cancellation)
                holders.append(contentsOf: classify(snapshot, in: scope))
                isComplete = isComplete && snapshot.isComplete
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

    private func inspect(
        pid: Int32,
        deadline: ContinuousClock.Instant,
        cancellation: ScanCancellation
    ) throws -> ProcessOccupancySnapshot {
        guard let cooperativeInspector = inspector as? any CooperativelyProcessInspecting else {
            return try inspector.inspect(pid: pid)
        }
        return try cooperativeInspector.inspect(pid: pid) {
            !cancellation.isCancelled && ContinuousClock.now < deadline
        }
    }

    private func shouldContinue(
        until deadline: ContinuousClock.Instant,
        cancellation: ScanCancellation
    ) -> Bool {
        !cancellation.isCancelled && ContinuousClock.now < deadline
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

private final class ScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

struct LiveProcessInspector: CooperativelyProcessInspecting {
    private enum InspectionError: Error {
        case unavailable
        case interrupted
    }

    private enum FDPathResult {
        case path(String?)
        case unavailable(Int32)
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
        let workingDirectoryResult = workingDirectory(pid: pid)
        let descriptorResult = try vnodePaths(pid: pid, while: shouldContinue)
        guard shouldContinue() else { throw InspectionError.interrupted }

        return ProcessOccupancySnapshot(
            pid: pid,
            executableName: executableName,
            displayName: NSRunningApplication(processIdentifier: pid)?.localizedName,
            openPaths: descriptorResult.paths.filter { !$0.hasPrefix("/dev/") },
            workingDirectory: workingDirectoryResult.path,
            deviceNodes: descriptorResult.paths.filter { $0.hasPrefix("/dev/") },
            isComplete: workingDirectoryResult.isComplete && descriptorResult.isComplete
        )
    }

    private func processName(pid: Int32) throws -> String {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &path, UInt32(path.count))
        guard length > 0 else { throw InspectionError.unavailable }
        return URL(fileURLWithPath: Self.decodePathBuffer(path)).lastPathComponent
    }

    private func workingDirectory(pid: Int32) -> (path: String?, isComplete: Bool) {
        var info = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        let returned = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, $0, Int32(size))
        }
        guard returned == size else { return (nil, false) }
        return (boundedString(from: &info.pvi_cdir.vip_path), true)
    }

    private func vnodePaths(
        pid: Int32,
        while shouldContinue: @escaping @Sendable () -> Bool
    ) throws -> (paths: [String], isComplete: Bool) {
        var paths: [String] = []
        let enumeration = BoundedProcessFDEnumerator.enumerate(pid: pid, while: shouldContinue)
        var isComplete = enumeration.isComplete
        for descriptor in enumeration.descriptors {
            guard shouldContinue() else { throw InspectionError.interrupted }
            guard descriptor.type == UInt32(PROX_FDTYPE_VNODE) else { continue }
            switch vnodePath(pid: pid, fd: descriptor.number) {
            case let .path(path?): paths.append(path)
            case .path(nil): break
            case let .unavailable(errorCode):
                if errorCode != EBADF && errorCode != ENOENT { isComplete = false }
            }
        }
        return (paths, isComplete)
    }

    private func vnodePath(pid: Int32, fd: Int32) -> FDPathResult {
        var info = vnode_fdinfowithpath()
        let size = MemoryLayout<vnode_fdinfowithpath>.size
        let returned = withUnsafeMutablePointer(to: &info) {
            proc_pidfdinfo(pid, fd, PROC_PIDFDVNODEPATHINFO, $0, Int32(size))
        }
        guard returned == size else { return .unavailable(errno) }
        return .path(boundedString(from: &info.pvip.vip_path))
    }

    static func decodePathBuffer(_ bytes: [CChar]) -> String {
        let utf8 = bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: utf8, as: UTF8.self)
    }

    private func boundedString<T>(from value: inout T) -> String? {
        withUnsafeBytes(of: &value) { bytes in
            guard bytes.first != 0 else { return nil }
            let bounded = bytes.prefix { $0 != 0 }
            return String(decoding: bounded, as: UTF8.self)
        }
    }
}
