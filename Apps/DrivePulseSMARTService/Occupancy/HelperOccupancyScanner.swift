import Darwin
import Foundation

struct HelperProcessSnapshot: Sendable {
    let pid: Int32
    let executableName: String
    let displayName: String?
    let types: Set<String>
    let isComplete: Bool
}

protocol HelperProcessInspecting: Sendable {
    func candidatePIDs(limit: Int) async throws -> [Int32]
    func inspect(
        pid: Int32,
        scope: HelperOccupancyScope,
        shouldContinue: @escaping @Sendable () -> Bool
    ) async throws -> HelperProcessSnapshot
}

extension HelperProcessInspecting {
    func inspect(pid: Int32, shouldContinue: @escaping @Sendable () -> Bool) async throws -> HelperProcessSnapshot {
        try await inspect(pid: pid, scope: HelperOccupancyScope(deviceNodes: [], mountPaths: []), shouldContinue: shouldContinue)
    }
}

actor HelperOccupancyScanner {
    private struct ActiveScan { let workflowID: UUID; let cancellation: HelperScanCancellation }
    private let inspector: any HelperProcessInspecting
    private let timeout: Duration
    private var active: ActiveScan?

    init(inspector: any HelperProcessInspecting = LiveHelperProcessInspector(), timeout: Duration = .seconds(3)) {
        self.inspector = inspector
        self.timeout = timeout
    }

    func scan(workflowID: UUID, scope: HelperOccupancyScope) async throws -> OccupancyScanResponse {
        try await scan(
            workflowID: workflowID,
            scope: scope,
            deadline: ContinuousClock.now.advanced(by: timeout),
            externalCancellation: HelperOperationCancellation()
        )
    }

    func scan(
        workflowID: UUID,
        scope: HelperOccupancyScope,
        deadline: ContinuousClock.Instant,
        externalCancellation: HelperOperationCancellation
    ) async throws -> OccupancyScanResponse {
        if let active {
            guard active.workflowID == workflowID else { throw HelperOccupancyError.helperBusy }
            active.cancellation.cancel()
        }
        let cancellation = HelperScanCancellation()
        active = ActiveScan(workflowID: workflowID, cancellation: cancellation)
        defer { if active?.cancellation === cancellation { active = nil } }

        let returnedCandidates = try await inspector.candidatePIDs(limit: OccupancyXPCLimits.maxCandidatePIDs)
        guard Self.shouldContinue(cancellation, externalCancellation, deadline) else {
            return OccupancyScanResponse(workflowID: workflowID, holders: [], isComplete: false)
        }
        let candidates = Array(returnedCandidates.prefix(OccupancyXPCLimits.maxCandidatePIDs))
        var holders: [OccupancyHolderMessage] = []
        var complete = returnedCandidates.count < OccupancyXPCLimits.maxCandidatePIDs
        for pid in candidates {
            guard Self.shouldContinue(cancellation, externalCancellation, deadline) else {
                return OccupancyScanResponse(workflowID: workflowID, holders: [], isComplete: false)
            }
            do {
                let snapshot = try await inspector.inspect(pid: pid, scope: scope) {
                    Self.shouldContinue(cancellation, externalCancellation, deadline)
                }
                guard Self.shouldContinue(cancellation, externalCancellation, deadline) else {
                    return OccupancyScanResponse(workflowID: workflowID, holders: [], isComplete: false)
                }
                complete = complete && snapshot.isComplete
                holders.append(contentsOf: snapshot.types.map {
                    OccupancyHolderMessage(pid: snapshot.pid, executableName: snapshot.executableName, displayName: snapshot.displayName, type: $0)
                })
                if holders.count >= OccupancyXPCLimits.maxHolders { complete = false; break }
            } catch { complete = false }
        }
        let encoded = try DrivePulseXPCMessages.encodeOccupancyResponse(
            OccupancyScanResponse(workflowID: workflowID, holders: holders, isComplete: complete)
        )
        return try DrivePulseXPCMessages.decodeOccupancyResponse(from: encoded)
    }

    nonisolated private static func shouldContinue(
        _ cancellation: HelperScanCancellation,
        _ externalCancellation: HelperOperationCancellation,
        _ deadline: ContinuousClock.Instant
    ) -> Bool {
        !Task.isCancelled
            && !cancellation.isCancelled
            && !externalCancellation.isCancelled
            && ContinuousClock.now < deadline
    }
}

private final class HelperScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

struct LiveHelperProcessInspector: HelperProcessInspecting {
    func candidatePIDs(limit: Int) async throws -> [Int32] {
        var pids = [Int32](repeating: 0, count: min(limit, OccupancyXPCLimits.maxCandidatePIDs))
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count >= 0 else { throw HelperOccupancyError.scanFailed }
        return pids.prefix(min(Int(count), pids.count)).filter { $0 > 0 }.sorted()
    }

    func inspect(pid: Int32, scope: HelperOccupancyScope, shouldContinue: @escaping @Sendable () -> Bool) async throws -> HelperProcessSnapshot {
        guard shouldContinue() else { throw CancellationError() }
        var executablePath = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &executablePath, UInt32(executablePath.count)) > 0 else { throw HelperOccupancyError.scanFailed }
        let decodedPath = String(
            decoding: executablePath.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        let name = URL(fileURLWithPath: decodedPath).lastPathComponent
        var types = Set<String>()
        var complete = true
        var vnode = proc_vnodepathinfo()
        let vnodeSize = MemoryLayout<proc_vnodepathinfo>.size
        if withUnsafeMutablePointer(to: &vnode, { proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, $0, Int32(vnodeSize)) }) == vnodeSize {
            let path = withUnsafeBytes(of: &vnode.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if contains(path: path, mounts: scope.mountPaths) { types.insert("workingDirectory") }
        } else { complete = false }

        let enumeration = BoundedProcessFDEnumerator.enumerate(pid: pid, while: shouldContinue)
        complete = complete && enumeration.isComplete
        for fd in enumeration.descriptors where fd.type == UInt32(PROX_FDTYPE_VNODE) {
            guard shouldContinue() else { throw CancellationError() }
            var info = vnode_fdinfowithpath()
            let size = MemoryLayout<vnode_fdinfowithpath>.size
            guard withUnsafeMutablePointer(to: &info, { proc_pidfdinfo(pid, fd.number, PROC_PIDFDVNODEPATHINFO, $0, Int32(size)) }) == size else { complete = false; continue }
            let path = withUnsafeBytes(of: &info.pvip.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if scope.deviceNodes.contains(path) { types.insert("deviceNode") }
            else if contains(path: path, mounts: scope.mountPaths) { types.insert("openFileOrDirectory") }
        }
        return HelperProcessSnapshot(pid: pid, executableName: name, displayName: nil, types: types, isComplete: complete)
    }

    private func contains(path: String, mounts: Set<String>) -> Bool {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        return mounts.contains { mount in
            let mountComponents = URL(fileURLWithPath: mount).standardizedFileURL.pathComponents
            return components.count >= mountComponents.count && Array(components.prefix(mountComponents.count)) == mountComponents
        }
    }
}
