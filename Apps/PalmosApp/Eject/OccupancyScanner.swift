import Foundation

protocol HelperOccupancyScanning: Sendable {
    func scan(workflowID: UUID, physicalBSDName: String) async throws -> OccupancyScanResult
}

protocol OccupancyScanning: Sendable {
    func scan(workflowID: UUID, scope: OccupancyTargetScope) async -> OccupancyScanResult
}

struct OccupancyScanner: OccupancyScanning {
    private static let holderLimit = 64

    private let appScanner: any AppOccupancyScanning
    private let helperScanner: any HelperOccupancyScanning
    private let appScanTimeout: Duration

    init(
        appScanner: any AppOccupancyScanning = AppOccupancyScanner(),
        helperScanner: any HelperOccupancyScanning,
        appScanTimeout: Duration = .seconds(3)
    ) {
        self.appScanner = appScanner
        self.helperScanner = helperScanner
        self.appScanTimeout = appScanTimeout
    }

    func scan(workflowID: UUID, scope: OccupancyTargetScope) async -> OccupancyScanResult {
        let appResult = await appScanner.scan(
            scope: scope,
            deadline: ContinuousClock.now.advanced(by: appScanTimeout)
        )
        guard Task.isCancelled == false else { return cancelledResult }
        let hasActionableAppHolder = appResult.holders.contains { $0.type != .unknown }
        guard hasActionableAppHolder == false || appResult.isComplete == false else {
            return normalized(appResult)
        }
        guard Task.isCancelled == false else { return cancelledResult }

        do {
            let helperResult = try await helperScanner.scan(
                workflowID: workflowID,
                physicalBSDName: scope.physicalBSDName
            )
            guard Task.isCancelled == false else { return cancelledResult }
            return normalized(.init(
                holders: appResult.holders + helperResult.holders,
                isComplete: helperResult.isComplete
            ))
        } catch {
            guard Task.isCancelled == false else { return cancelledResult }
            return normalized(.init(holders: appResult.holders, isComplete: false))
        }
    }

    private var cancelledResult: OccupancyScanResult {
        OccupancyScanResult(holders: [], isComplete: false)
    }

    private func normalized(_ result: OccupancyScanResult) -> OccupancyScanResult {
        var unique: [HolderKey: OccupancyHolder] = [:]
        for holder in result.holders {
            let key = HolderKey(pid: holder.pid, type: holder.type)
            if let existing = unique[key] {
                if isPreferred(holder, over: existing) { unique[key] = holder }
            } else {
                unique[key] = holder
            }
        }
        return OccupancyScanResult(
            holders: Array(unique.values.sorted(by: holderSort).prefix(Self.holderLimit)),
            isComplete: result.isComplete && unique.count <= Self.holderLimit
        )
    }

    private func isPreferred(_ candidate: OccupancyHolder, over existing: OccupancyHolder) -> Bool {
        let candidateHasDisplayName = candidate.displayName?.isEmpty == false
        let existingHasDisplayName = existing.displayName?.isEmpty == false
        if candidateHasDisplayName != existingHasDisplayName { return candidateHasDisplayName }
        if candidate.preferredName != existing.preferredName {
            return candidate.preferredName < existing.preferredName
        }
        return candidate.executableName < existing.executableName
    }

    private func holderSort(_ lhs: OccupancyHolder, _ rhs: OccupancyHolder) -> Bool {
        if lhs.preferredName != rhs.preferredName { return lhs.preferredName < rhs.preferredName }
        if lhs.pid != rhs.pid { return lhs.pid < rhs.pid }
        return lhs.type.rawValue < rhs.type.rawValue
    }
}

private struct HolderKey: Hashable {
    let pid: Int32
    let type: OccupancyType
}
