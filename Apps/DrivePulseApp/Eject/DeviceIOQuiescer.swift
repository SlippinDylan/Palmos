import Foundation

import DrivePulseCore

actor DeviceIOTracker {
    fileprivate enum TargetQuiescence {
        case drained
        case pending
        case smartCompletionUnobservable
    }

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
        let deviceID: DeviceID?
        let physicalBSDName: String?
        let topologyGeneration: Int
        let kind: Kind
    }

    private struct SMARTSafetyScope: Hashable, Sendable {
        let deviceID: DeviceID?
        let physicalBSDName: String
        let topologyGeneration: Int
    }

    private var operations: [Token: Operation] = [:]
    private var unobservableSMARTScopes: Set<SMARTSafetyScope> = []
    private var targetBarriers: [String: Int] = [:]
    private var latestSafetyPruneGeneration = Int.min

    func beginTargetOperation(
        deviceID: DeviceID? = nil,
        physicalBSDName: String,
        topologyGeneration: Int = 0,
        kind: Kind
    ) throws -> Token {
        guard physicalBSDName.isEmpty == false else { throw RegistrationError.invalidScope }
        guard targetBarriers[physicalBSDName, default: 0] == 0 else {
            throw RegistrationError.paused
        }
        let token = Token(id: UUID())
        operations[token] = Operation(
            deviceID: deviceID,
            physicalBSDName: physicalBSDName,
            topologyGeneration: topologyGeneration,
            kind: kind
        )
        return token
    }

    func beginGlobalOperation(kind: Kind) throws -> Token {
        let token = Token(id: UUID())
        operations[token] = Operation(
            deviceID: nil,
            physicalBSDName: nil,
            topologyGeneration: 0,
            kind: kind
        )
        return token
    }

    func finish(_ token: Token) {
        operations.removeValue(forKey: token)
    }

    func finishSMARTCompletion(
        _ token: Token,
        clearsPriorSafetyScopes: Bool
    ) {
        guard let operation = operations.removeValue(forKey: token),
              operation.kind == .smart,
              let physicalBSDName = operation.physicalBSDName else {
            return
        }
        guard clearsPriorSafetyScopes else { return }
        unobservableSMARTScopes = unobservableSMARTScopes.filter { scope in
            scope.deviceID != operation.deviceID
                || scope.physicalBSDName != physicalBSDName
                || scope.topologyGeneration > operation.topologyGeneration
        }
    }

    func markSMARTCompletionUnobservable(_ token: Token) {
        guard let operation = operations.removeValue(forKey: token),
              operation.kind == .smart,
              let physicalBSDName = operation.physicalBSDName else {
            return
        }
        unobservableSMARTScopes.insert(.init(
            deviceID: operation.deviceID,
            physicalBSDName: physicalBSDName,
            topologyGeneration: operation.topologyGeneration
        ))
    }

    /// Drops safety scopes that no longer belong to a live device session.
    ///
    /// A completion that was not acknowledged must remain fail-closed while its
    /// device session is live. Once discovery proves that the session vanished
    /// (or the BSD name was reassigned), retaining the scope only leaks state and
    /// can block a later, unrelated eject workflow.
    func pruneSMARTSafetyScopes(
        liveDeviceIDs: Set<DeviceID>,
        livePhysicalBSDNames: Set<String>,
        topologyGeneration: Int
    ) {
        guard topologyGeneration >= latestSafetyPruneGeneration else { return }
        latestSafetyPruneGeneration = topologyGeneration
        unobservableSMARTScopes = unobservableSMARTScopes.filter { scope in
            if scope.topologyGeneration > topologyGeneration { return true }
            guard livePhysicalBSDNames.contains(scope.physicalBSDName) else {
                return false
            }
            guard let deviceID = scope.deviceID else {
                return true
            }
            return liveDeviceIDs.contains(deviceID)
        }
    }

    func inFlightKinds(for physicalBSDName: String) -> Set<Kind> {
        Set(operations.values.compactMap { operation in
            operation.physicalBSDName == physicalBSDName ? operation.kind : nil
        })
    }

    fileprivate func installBarrier(for physicalBSDName: String) {
        targetBarriers[physicalBSDName, default: 0] += 1
    }

    fileprivate func removeBarrier(for physicalBSDName: String) {
        if targetBarriers[physicalBSDName] == 1 {
            targetBarriers.removeValue(forKey: physicalBSDName)
        } else if let count = targetBarriers[physicalBSDName] {
            targetBarriers[physicalBSDName] = count - 1
        }
    }

    fileprivate func quiescence(
        deviceID: DeviceID,
        physicalBSDName: String
    ) -> TargetQuiescence {
        if unobservableSMARTScopes.contains(where: { scope in
            scope.physicalBSDName == physicalBSDName
                && (scope.deviceID == deviceID || scope.deviceID == nil)
        }) {
            return .smartCompletionUnobservable
        }
        let hasRelevantOperation = operations.values.contains { operation in
            operation.physicalBSDName == physicalBSDName
        }
        return hasRelevantOperation ? .pending : .drained
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
            deviceID: target.deviceID,
            physicalBSDName: target.physicalBSDName,
            timeout: timeout
        )
    }
}

private actor DeviceIOBarrier: EjectBarrier {
    private let tracker: DeviceIOTracker
    private let deviceID: DeviceID
    private let physicalBSDName: String
    private let timeout: Duration
    private var isReleased = false

    init(
        tracker: DeviceIOTracker,
        deviceID: DeviceID,
        physicalBSDName: String,
        timeout: Duration
    ) {
        self.tracker = tracker
        self.deviceID = deviceID
        self.physicalBSDName = physicalBSDName
        self.timeout = timeout
    }

    func waitUntilReady() async throws {
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [tracker, deviceID, physicalBSDName] in
                    while true {
                        switch await tracker.quiescence(
                            deviceID: deviceID,
                            physicalBSDName: physicalBSDName
                        ) {
                        case .drained:
                            return
                        case .smartCompletionUnobservable:
                            throw DeviceIOQuiescenceError.legacySMARTCompletionUnobservable
                        case .pending:
                            break
                        }
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
