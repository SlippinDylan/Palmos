import Foundation

actor DeviceIOTracker {
    enum Kind: Hashable, Sendable {
        case smart, capacity, metadata, diskutil, systemProfiler
    }

    enum RegistrationError: Error, Equatable, Sendable {
        case paused
        case invalidScope
    }

    struct Token: Hashable, Sendable {
        fileprivate let id: UUID
    }

    private struct Operation: Sendable {
        let physicalBSDName: String?
        let kind: Kind
    }

    private var operations: [Token: Operation] = [:]
    private var targetBarriers: [String: Int] = [:]
    private var globalBarrierCount = 0

    func beginTargetOperation(physicalBSDName: String, kind: Kind) throws -> Token {
        guard physicalBSDName.isEmpty == false else { throw RegistrationError.invalidScope }
        guard targetBarriers[physicalBSDName, default: 0] == 0 else {
            throw RegistrationError.paused
        }
        let token = Token(id: UUID())
        operations[token] = Operation(physicalBSDName: physicalBSDName, kind: kind)
        return token
    }

    func beginGlobalOperation(kind: Kind) throws -> Token {
        guard globalBarrierCount == 0 else { throw RegistrationError.paused }
        let token = Token(id: UUID())
        operations[token] = Operation(physicalBSDName: nil, kind: kind)
        return token
    }

    func finish(_ token: Token) {
        operations.removeValue(forKey: token)
    }

    func inFlightKinds(for physicalBSDName: String) -> Set<Kind> {
        Set(operations.values.compactMap { operation in
            operation.physicalBSDName == physicalBSDName ? operation.kind : nil
        })
    }

    fileprivate func installBarrier(for physicalBSDName: String) {
        targetBarriers[physicalBSDName, default: 0] += 1
        globalBarrierCount += 1
    }

    fileprivate func removeBarrier(for physicalBSDName: String) {
        if targetBarriers[physicalBSDName] == 1 {
            targetBarriers.removeValue(forKey: physicalBSDName)
        } else if let count = targetBarriers[physicalBSDName] {
            targetBarriers[physicalBSDName] = count - 1
        }
        globalBarrierCount = max(0, globalBarrierCount - 1)
    }

    fileprivate func isDrained(for physicalBSDName: String) -> Bool {
        operations.values.contains { operation in
            operation.physicalBSDName == nil || operation.physicalBSDName == physicalBSDName
        } == false
    }
}

protocol DeviceIOQuiescing: Sendable {
    func acquireBarrier(
        for target: EjectWorkflowTarget,
        timeout: Duration
    ) async throws(DeviceIOQuiescenceError) -> any EjectBarrier
}

struct DeviceIOQuiescer: DeviceIOQuiescing, Sendable {
    let tracker: DeviceIOTracker

    func acquireBarrier(
        for target: EjectWorkflowTarget,
        timeout: Duration
    ) async throws(DeviceIOQuiescenceError) -> any EjectBarrier {
        guard Task.isCancelled == false else { throw .cancelled }
        await tracker.installBarrier(for: target.physicalBSDName)
        return DeviceIOBarrier(
            tracker: tracker,
            physicalBSDName: target.physicalBSDName,
            timeout: timeout
        )
    }
}

private actor DeviceIOBarrier: EjectBarrier {
    private let tracker: DeviceIOTracker
    private let physicalBSDName: String
    private let timeout: Duration
    private var isReleased = false

    init(tracker: DeviceIOTracker, physicalBSDName: String, timeout: Duration) {
        self.tracker = tracker
        self.physicalBSDName = physicalBSDName
        self.timeout = timeout
    }

    func waitUntilReady() async throws {
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [tracker, physicalBSDName] in
                    while await tracker.isDrained(for: physicalBSDName) == false {
                        try Task.checkCancellation()
                        try await Task.sleep(for: .milliseconds(2))
                    }
                }
                group.addTask { [timeout] in
                    try await Task.sleep(for: timeout)
                    throw DeviceIOQuiescenceError.timedOut
                }
                _ = try await group.next()
                group.cancelAll()
            }
        } catch is CancellationError {
            throw DeviceIOQuiescenceError.cancelled
        }
    }

    func release() async {
        guard isReleased == false else { return }
        isReleased = true
        await tracker.removeBarrier(for: physicalBSDName)
    }
}
