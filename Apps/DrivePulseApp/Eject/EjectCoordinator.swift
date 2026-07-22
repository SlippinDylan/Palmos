import Combine
import Foundation

import DrivePulseCore

@MainActor
final class EjectCoordinator: ObservableObject {
    @Published private(set) var state: EjectWorkflowState = .idle
    @Published private(set) var retainedRecovery: EjectRecoveryState?

    private let resolver: any EjectTargetResolving
    private let quiescer: any DeviceIOQuiescing
    private let ejecter: any DiskEjecting
    private let occupancyScanner: any OccupancyScanning
    private let preparationTimeout: Duration

    private var workflowID: UUID?
    private var pendingTarget: EjectWorkflowTarget?
    private var activeWorkflow: ActiveWorkflow?
    private var operationTask: Task<Void, Never>?
    private var topologyValidationTask: Task<Void, Never>?
    private var latestTopologyGeneration: Int?
    private var validatedTopologyGeneration: Int?
    private var releaseWorkflowID: UUID?
    private var releaseTask: Task<Void, Never>?

    init(
        resolver: any EjectTargetResolving,
        quiescer: any DeviceIOQuiescing,
        ejecter: any DiskEjecting,
        occupancyScanner: any OccupancyScanning,
        preparationTimeout: Duration = .seconds(10)
    ) {
        self.resolver = resolver
        self.quiescer = quiescer
        self.ejecter = ejecter
        self.occupancyScanner = occupancyScanner
        self.preparationTimeout = preparationTimeout
    }

    func begin(deviceID: DeviceID, displayName: String, topologyGeneration: Int) {
        guard workflowID == nil else { return }
        let id = UUID()
        let request = EjectWorkflowRequest(deviceID: deviceID, displayName: displayName)
        workflowID = id
        latestTopologyGeneration = topologyGeneration
        validatedTopologyGeneration = topologyGeneration
        state = .preparing(request)
        operationTask = Task { [weak self] in
            await self?.prepareAndEject(
                workflowID: id,
                deviceID: deviceID,
                displayName: displayName,
                topologyGeneration: topologyGeneration
            )
        }
    }

    func cancel() {
        guard let id = workflowID else { return }
        operationTask?.cancel()
        topologyValidationTask?.cancel()
        operationTask = Task { [weak self] in
            await self?.finishCancellation(workflowID: id)
        }
    }

    func retry() {
        guard case .awaitingRecovery(let recovery) = state,
              let activeWorkflow else { return }
        retainedRecovery = recovery
        state = .working(target: activeWorkflow.target, stage: .preparing)
        startOperation(workflowID: activeWorkflow.id) { [weak self] in
            await self?.prepareExistingAttempt(workflowID: activeWorkflow.id, force: false)
        }
    }

    func requestForce() {
        guard case .awaitingRecovery(let recovery) = state else { return }
        state = .awaitingForceConfirmation(recovery)
    }

    func cancelForceConfirmation() {
        guard case .awaitingForceConfirmation(let recovery) = state else { return }
        state = .awaitingRecovery(recovery)
    }

    func confirmForce() {
        guard case .awaitingForceConfirmation(let recovery) = state,
              let activeWorkflow else { return }
        retainedRecovery = recovery
        state = .working(target: activeWorkflow.target, stage: .preparing)
        startOperation(workflowID: activeWorkflow.id) { [weak self] in
            await self?.prepareExistingAttempt(workflowID: activeWorkflow.id, force: true)
        }
    }

    func deviceTopologyDidChange(generation: Int) {
        guard workflowID != nil,
              generation > (latestTopologyGeneration ?? Int.min) else {
            return
        }
        latestTopologyGeneration = generation
        guard let activeWorkflow else { return }
        topologyValidationTask?.cancel()
        topologyValidationTask = Task { [weak self] in
            await self?.revalidateForTopologyChange(
                workflowID: activeWorkflow.id,
                generation: generation
            )
        }
    }

    private func prepareAndEject(
        workflowID id: UUID,
        deviceID: DeviceID,
        displayName: String,
        topologyGeneration: Int
    ) async {
        do {
            let resolved = try await resolver.resolve(
                deviceID: deviceID,
                displayName: displayName,
                topologyGeneration: topologyGeneration
            )
            guard isCurrent(id) else { return }
            pendingTarget = resolved.target
            state = .working(target: resolved.target, stage: .preparing)

            let barrier = try await quiescer.acquireBarrier(
                for: resolved.target,
                timeout: preparationTimeout
            )
            guard isCurrent(id) else {
                await barrier.release()
                return
            }
            activeWorkflow = ActiveWorkflow(
                id: id,
                target: resolved.target,
                scope: resolved.scope,
                barrier: barrier
            )
            pendingTarget = nil
            try await barrier.waitUntilReady()
            guard isCurrent(id) else { return }
            await revalidateAndPerformNormalEject(workflowID: id)
        } catch let error as DeviceIOQuiescenceError {
            guard let target = activeWorkflow?.target ?? pendingTarget, isCurrent(id) else { return }
            await finishFailure(
                preparationFailure(error, target: target),
                target: target,
                workflowID: id
            )
        } catch {
            guard isCurrent(id) else { return }
            if let target = activeWorkflow?.target {
                await handleRevalidationError(error, target: target, workflowID: id)
            } else {
                let request = EjectWorkflowRequest(deviceID: deviceID, displayName: displayName)
                let failure = resolutionFailure(error)
                clearWorkflow(id)
                state = .resolutionFailed(request: request, failure: failure)
            }
        }
    }

    private func revalidateAndPerformNormalEject(workflowID id: UUID) async {
        guard let workflow = activeWorkflow, workflow.id == id else { return }
        do {
            guard try await revalidateForOperation(workflow: workflow) != nil else { return }
            state = .working(target: workflow.target, stage: .unmounting)
            let result = await ejecter.performNormalEject(
                target: workflow.target.physicalIdentity,
                scope: workflow.scope
            )
            guard isCurrent(id) else { return }
            await handleNormalResult(result, workflow: workflow)
        } catch {
            await handleRevalidationError(error, target: workflow.target, workflowID: id)
        }
    }

    private func prepareExistingAttempt(workflowID id: UUID, force: Bool) async {
        guard let workflow = activeWorkflow, workflow.id == id else { return }
        do {
            let barrier = try await quiescer.acquireBarrier(
                for: workflow.target,
                timeout: preparationTimeout
            )
            guard isCurrent(id) else {
                await barrier.release()
                return
            }
            workflow.setBarrier(barrier)
            try await barrier.waitUntilReady()
            guard isCurrent(id) else { return }
            if force {
                await revalidateAndPerformForceEject(workflowID: id)
            } else {
                await revalidateAndPerformNormalEject(workflowID: id)
            }
        } catch let error as DeviceIOQuiescenceError {
            guard isCurrent(id) else { return }
            await finishFailure(
                preparationFailure(error, target: workflow.target),
                target: workflow.target,
                workflowID: id
            )
        } catch {
            await handleRevalidationError(error, target: workflow.target, workflowID: id)
        }
    }

    private func revalidateAndPerformForceEject(workflowID id: UUID) async {
        guard let workflow = activeWorkflow, workflow.id == id else { return }
        do {
            guard try await revalidateForOperation(workflow: workflow) != nil else { return }
            state = .working(target: workflow.target, stage: .forceUnmounting)
            let result = await ejecter.performConfirmedForceEject(target: workflow.target.physicalIdentity)
            guard isCurrent(id) else { return }
            switch result {
            case .success:
                await finishSuccess(workflow: workflow)
            case .failure(let failure):
                await finishFailure(failure, target: workflow.target, workflowID: id)
            case .targetInvalidated:
                await finishDisappearance(target: workflow.target, workflowID: id)
            }
        } catch {
            await handleRevalidationError(error, target: workflow.target, workflowID: id)
        }
    }

    private func revalidateForTopologyChange(workflowID id: UUID, generation: Int) async {
        guard let workflow = activeWorkflow, workflow.id == id else { return }
        do {
            let refreshed = try await resolver.revalidate(workflow.target)
            guard isCurrent(id), latestTopologyGeneration == generation else { return }
            validatedTopologyGeneration = generation
            workflow.refreshScope(refreshed.scope, generation: generation)
            if shouldEndRecoveryAfterExternalUnmount(workflow: workflow) {
                operationTask?.cancel()
                await finishExternalUnmount(workflowID: id)
                return
            }
        } catch {
            guard isCurrent(id), latestTopologyGeneration == generation else { return }
            if isDisappearance(error) {
                operationTask?.cancel()
                await finishDisappearance(target: workflow.target, workflowID: id)
            } else {
                operationTask?.cancel()
                await handleRevalidationError(error, target: workflow.target, workflowID: id)
            }
        }
    }

    private func revalidateForOperation(
        workflow: ActiveWorkflow
    ) async throws -> ResolvedEjectTarget? {
        while isCurrent(workflow.id) {
            let generation = latestTopologyGeneration ?? workflow.target.topologyGeneration
            if (validatedTopologyGeneration ?? Int.min) < generation {
                if let topologyValidationTask {
                    await topologyValidationTask.value
                    guard isCurrent(workflow.id) else { return nil }
                    continue
                }

                let refreshed = try await resolver.revalidate(workflow.target)
                guard isCurrent(workflow.id) else { return nil }
                guard latestTopologyGeneration == generation else { continue }
                validatedTopologyGeneration = generation
                workflow.refreshScope(refreshed.scope, generation: generation)
                return refreshed
            }

            let refreshed = try await resolver.revalidate(workflow.target)
            guard isCurrent(workflow.id) else { return nil }
            guard latestTopologyGeneration == generation,
                  (validatedTopologyGeneration ?? Int.min) >= generation else {
                continue
            }
            workflow.refreshScope(refreshed.scope, generation: generation)
            return refreshed
        }
        return nil
    }

    private func handleNormalResult(
        _ result: DiskEjectOutcome,
        workflow: ActiveWorkflow
    ) async {
        switch result {
        case .success:
            await finishSuccess(workflow: workflow)
        case .targetInvalidated:
            await finishDisappearance(target: workflow.target, workflowID: workflow.id)
        case .failure(let failure) where failure.category == .busy:
            await beginRecovery(failure: failure, workflow: workflow)
        case .failure(let failure):
            await finishFailure(failure, target: workflow.target, workflowID: workflow.id)
        }
    }

    private func beginRecovery(
        failure: EjectFailure,
        workflow: ActiveWorkflow
    ) async {
        let holders: [OccupancyHolder]
        if failure.holders.isEmpty {
            state = .working(target: workflow.target, stage: .diagnosingOccupancy)
            let scan = await occupancyScanner.scan(workflowID: workflow.id, scope: workflow.scope)
            guard isCurrent(workflow.id) else { return }
            holders = scan.holders
        } else {
            holders = failure.holders
        }

        if workflow.hasObservedExternalUnmount {
            await finishExternalUnmount(workflowID: workflow.id)
            return
        }

        var diagnosedFailure = failure
        diagnosedFailure.holders = holders
        let recovery = EjectRecoveryState(
            target: workflow.target,
            failure: diagnosedFailure,
            holders: holders
        )
        await releaseBarrier(workflowID: workflow.id)
        guard isCurrent(workflow.id) else { return }
        if workflow.hasObservedExternalUnmount {
            await finishExternalUnmount(workflowID: workflow.id)
            return
        }
        retainedRecovery = recovery
        state = .awaitingRecovery(recovery)
    }

    private func handleRevalidationError(
        _ error: Error,
        target: EjectWorkflowTarget,
        workflowID id: UUID
    ) async {
        guard isCurrent(id) else { return }
        if isDisappearance(error) {
            await finishDisappearance(target: target, workflowID: id)
            return
        }

        let failure = EjectFailure(
            stage: .preparing,
            category: .unknown,
            rawStatus: nil,
            systemMessage: String(describing: error),
            physicalBSDName: target.physicalBSDName,
            holders: []
        )
        await finishFailure(failure, target: target, workflowID: id)
    }

    private func resolutionFailure(_ error: Error) -> EjectFailure {
        let category: EjectFailureCategory
        switch error as? EjectTargetResolutionError {
        case .deviceNotFound:
            category = .notFound
        case .unsafeMedia:
            category = .notPermitted
        case .incompleteMediaIdentity, .targetChanged, nil:
            category = .unknown
        }
        return EjectFailure(
            stage: .preparing,
            category: category,
            rawStatus: nil,
            systemMessage: nil,
            physicalBSDName: "",
            holders: []
        )
    }

    private func finishSuccess(workflow: ActiveWorkflow) async {
        await releaseBarrier(workflowID: workflow.id)
        guard canCommitTerminal(workflow.id) else { return }
        state = .succeeded(workflow.target)
        clearWorkflow(workflow.id)
    }

    private func finishFailure(
        _ failure: EjectFailure,
        target: EjectWorkflowTarget,
        workflowID id: UUID
    ) async {
        await releaseBarrier(workflowID: id)
        guard canCommitTerminal(id) else { return }
        state = .failed(target: target, failure: failure)
        clearWorkflow(id)
    }

    private func finishDisappearance(target: EjectWorkflowTarget, workflowID id: UUID) async {
        await releaseBarrier(workflowID: id)
        guard canCommitTerminal(id) else { return }
        state = .disappeared(target)
        clearWorkflow(id)
    }

    private func finishExternalUnmount(workflowID id: UUID) async {
        guard let target = activeWorkflow?.target else { return }
        await releaseBarrier(workflowID: id)
        guard canCommitTerminal(id) else { return }
        state = .externallyUnmounted(target)
        clearWorkflow(id)
    }

    private func finishCancellation(workflowID id: UUID) async {
        guard isCurrent(id) else { return }
        await releaseBarrier(workflowID: id)
        guard workflowID == id else { return }
        state = .idle
        clearWorkflow(id)
    }

    private func releaseBarrier(workflowID id: UUID) async {
        if releaseWorkflowID == id, let releaseTask {
            await releaseTask.value
            return
        }
        guard let workflow = activeWorkflow,
              workflow.id == id,
              let barrier = workflow.takeBarrier() else { return }
        let task = Task { await barrier.release() }
        releaseWorkflowID = id
        releaseTask = task
        await task.value
        if releaseWorkflowID == id {
            releaseWorkflowID = nil
            releaseTask = nil
        }
    }

    private func startOperation(
        workflowID id: UUID,
        operation: @escaping @MainActor @Sendable () async -> Void
    ) {
        operationTask?.cancel()
        operationTask = Task { await operation() }
    }

    private func clearWorkflow(_ id: UUID) {
        guard workflowID == id else { return }
        workflowID = nil
        pendingTarget = nil
        activeWorkflow = nil
        operationTask = nil
        topologyValidationTask = nil
        latestTopologyGeneration = nil
        validatedTopologyGeneration = nil
        releaseWorkflowID = nil
        releaseTask = nil
        retainedRecovery = nil
    }

    private func isCurrent(_ id: UUID) -> Bool {
        workflowID == id && Task.isCancelled == false
    }

    private func canCommitTerminal(_ id: UUID) -> Bool {
        workflowID == id && Task.isCancelled == false
    }

    private func isDisappearance(_ error: Error) -> Bool {
        guard let error = error as? EjectTargetResolutionError else { return false }
        return error == .deviceNotFound || error == .targetChanged
    }

    private func shouldEndRecoveryAfterExternalUnmount(workflow: ActiveWorkflow) -> Bool {
        guard workflow.hasObservedExternalUnmount else { return false }
        switch state {
        case .awaitingRecovery(let recovery), .awaitingForceConfirmation(let recovery):
            return recovery.target == workflow.target
        default:
            return false
        }
    }

    private func preparationFailure(
        _ error: DeviceIOQuiescenceError,
        target: EjectWorkflowTarget
    ) -> EjectFailure {
        let category: EjectFailureCategory = switch error {
        case .timedOut: .timedOut
        case .legacySMARTCompletionUnobservable: .smartCompletionUnobservable
        case .cancelled: .unknown
        }
        return EjectFailure(
            stage: .preparing,
            category: category,
            rawStatus: nil,
            systemMessage: nil,
            physicalBSDName: target.physicalBSDName,
            holders: []
        )
    }
}

@MainActor
private final class ActiveWorkflow {
    let id: UUID
    let target: EjectWorkflowTarget
    var scope: OccupancyTargetScope
    private(set) var scopeGeneration: Int
    private(set) var hasObservedExternalUnmount = false
    private var barrier: (any EjectBarrier)?

    init(
        id: UUID,
        target: EjectWorkflowTarget,
        scope: OccupancyTargetScope,
        barrier: any EjectBarrier
    ) {
        self.id = id
        self.target = target
        self.scope = scope
        self.scopeGeneration = target.topologyGeneration
        self.barrier = barrier
    }

    func refreshScope(_ scope: OccupancyTargetScope, generation: Int) {
        guard generation >= scopeGeneration else { return }
        if self.scope.mountURLs.isEmpty == false, scope.mountURLs.isEmpty {
            hasObservedExternalUnmount = true
        }
        self.scope = scope
        scopeGeneration = generation
    }

    func setBarrier(_ barrier: any EjectBarrier) {
        precondition(self.barrier == nil)
        self.barrier = barrier
    }

    func takeBarrier() -> (any EjectBarrier)? {
        defer { barrier = nil }
        return barrier
    }
}
