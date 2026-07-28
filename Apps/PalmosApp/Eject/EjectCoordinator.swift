import Combine
import Foundation

import PalmosCore

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
    private var diagnosisTask: Task<Void, Never>?
    private var topologyValidationTask: Task<Void, Never>?
    private var latestTopologyGeneration: Int?
    private var validatedTopologyGeneration: Int?
    private var releaseWorkflowID: UUID?
    private var releaseTask: Task<Void, Never>?
    private var cancellationWorkflowID: UUID?

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

    @discardableResult
    func begin(deviceID: DeviceID, displayName: String, topologyGeneration: Int) -> Bool {
        guard workflowID == nil else { return false }
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
        return true
    }

    func cancel() {
        guard let id = workflowID else { return }
        guard cancellationWorkflowID != id else { return }
        cancellationWorkflowID = id
        let inFlightOperation = operationTask
        inFlightOperation?.cancel()
        diagnosisTask?.cancel()
        topologyValidationTask?.cancel()
        if case .working = state {
            // Keep the submitted stage visible until its real completion arrives.
        } else if let target = activeWorkflow?.target {
            state = .working(target: target, stage: .preparing)
        }
        operationTask = Task { [weak self] in
            await inFlightOperation?.value
            await self?.finishCancellation(workflowID: id)
        }
    }

    func cancelAndWait() async {
        cancel()
        await operationTask?.value
    }

    func retry() {
        guard cancellationWorkflowID == nil,
              case .awaitingRecovery(let recovery) = state,
              let activeWorkflow else { return }
        diagnosisTask?.cancel()
        let attempt = activeWorkflow.beginNextAttempt()
        retainedRecovery = recovery
        state = .working(target: activeWorkflow.target, stage: .preparing)
        startOperation(workflowID: activeWorkflow.id) { [weak self] in
            await self?.prepareExistingAttempt(
                workflowID: activeWorkflow.id,
                attempt: attempt,
                force: false
            )
        }
    }

    func requestForce() {
        guard cancellationWorkflowID == nil,
              case .awaitingRecovery(let recovery) = state else { return }
        state = .awaitingForceConfirmation(recovery)
    }

    func cancelForceConfirmation() {
        guard cancellationWorkflowID == nil,
              case .awaitingForceConfirmation(let recovery) = state else { return }
        state = .awaitingRecovery(recovery)
    }

    func confirmForce() {
        guard cancellationWorkflowID == nil,
              case .awaitingForceConfirmation(let recovery) = state,
              let activeWorkflow else { return }
        diagnosisTask?.cancel()
        let attempt = activeWorkflow.beginNextAttempt()
        retainedRecovery = recovery
        state = .working(target: activeWorkflow.target, stage: .preparing)
        startOperation(workflowID: activeWorkflow.id) { [weak self] in
            await self?.prepareExistingAttempt(
                workflowID: activeWorkflow.id,
                attempt: attempt,
                force: true
            )
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
                operationPlan: resolved.operationPlan,
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
            let result = await ejecter.performNormalEject(plan: workflow.operationPlan)
            guard isCurrent(id) else { return }
            await handleNormalResult(result, workflow: workflow)
        } catch {
            await handleRevalidationError(error, target: workflow.target, workflowID: id)
        }
    }

    private func prepareExistingAttempt(workflowID id: UUID, attempt: Int, force: Bool) async {
        guard let workflow = activeWorkflow,
              workflow.id == id,
              isCurrentAttempt(id, attempt: attempt) else { return }
        if force {
            await revalidateAndPerformForceEject(workflowID: id)
        } else {
            await revalidateAndPerformNormalEject(workflowID: id)
        }
    }

    private func revalidateAndPerformForceEject(workflowID id: UUID) async {
        guard let workflow = activeWorkflow, workflow.id == id else { return }
        do {
            guard try await revalidateForOperation(workflow: workflow) != nil else { return }
            state = .working(target: workflow.target, stage: .forceUnmounting)
            let result = await ejecter.performConfirmedForceEject(plan: workflow.operationPlan)
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
            workflow.refresh(refreshed, generation: generation)
            if shouldEndRecoveryAfterExternalUnmount(workflow: workflow) {
                await cancelActiveOperationBeforeTerminalTransition()
                await finishExternalUnmount(workflowID: id)
                return
            }
            restartDiagnosisAfterTopologyRefresh(workflow: workflow)
        } catch {
            guard isCurrent(id), latestTopologyGeneration == generation else { return }
            if isDisappearance(error) {
                await cancelActiveOperationBeforeTerminalTransition()
                await finishDisappearance(target: workflow.target, workflowID: id)
            } else {
                await cancelActiveOperationBeforeTerminalTransition()
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
                workflow.refresh(refreshed, generation: generation)
                return refreshed
            }

            let refreshed = try await resolver.revalidate(workflow.target)
            guard isCurrent(workflow.id) else { return nil }
            guard latestTopologyGeneration == generation,
                  (validatedTopologyGeneration ?? Int.min) >= generation else {
                continue
            }
            workflow.refresh(refreshed, generation: generation)
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
        if workflow.hasObservedExternalUnmount {
            await finishExternalUnmount(workflowID: workflow.id)
            return
        }

        let diagnosis: OccupancyDiagnosis = failure.holders.isEmpty
            ? .pending
            : .known(failure.holders)
        let recovery = EjectRecoveryState(
            target: workflow.target,
            failure: failure,
            diagnosis: diagnosis
        )
        retainedRecovery = recovery
        state = .awaitingRecovery(recovery)

        if failure.holders.isEmpty {
            startDiagnosis(workflow: workflow, failure: failure)
        }
    }

    private func startDiagnosis(workflow: ActiveWorkflow, failure: EjectFailure) {
        diagnosisTask?.cancel()
        let attempt = workflow.attemptGeneration
        let scopeGeneration = workflow.scopeGeneration
        let scope = workflow.scope
        diagnosisTask = Task { [weak self] in
            guard let self else { return }
            let scan = await occupancyScanner.scan(workflowID: workflow.id, scope: scope)
            guard isCurrentAttempt(workflow.id, attempt: attempt),
                  activeWorkflow?.scopeGeneration == scopeGeneration else { return }
            var diagnosedFailure = failure
            diagnosedFailure.holders = scan.holders
            let diagnosis: OccupancyDiagnosis
            if scan.holders.isEmpty == false {
                diagnosis = .known(scan.holders)
            } else if scan.isComplete {
                diagnosis = .unknown
            } else {
                diagnosis = .unavailable
            }
            let recovery = EjectRecoveryState(
                target: workflow.target,
                failure: diagnosedFailure,
                diagnosis: diagnosis
            )
            retainedRecovery = recovery
            switch state {
            case .awaitingRecovery:
                state = .awaitingRecovery(recovery)
            case .awaitingForceConfirmation:
                state = .awaitingForceConfirmation(recovery)
            default:
                break
            }
        }
    }

    private func restartDiagnosisAfterTopologyRefresh(workflow: ActiveWorkflow) {
        let previous: EjectRecoveryState
        let isConfirmingForce: Bool
        switch state {
        case .awaitingRecovery(let recovery):
            previous = recovery
            isConfirmingForce = false
        case .awaitingForceConfirmation(let recovery):
            previous = recovery
            isConfirmingForce = true
        default:
            return
        }

        var failure = previous.failure
        failure.holders = []
        let pending = EjectRecoveryState(
            target: workflow.target,
            failure: failure,
            diagnosis: .pending
        )
        retainedRecovery = pending
        state = isConfirmingForce
            ? .awaitingForceConfirmation(pending)
            : .awaitingRecovery(pending)
        startDiagnosis(workflow: workflow, failure: failure)
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

    private func cancelActiveOperationBeforeTerminalTransition() async {
        let inFlightOperation = operationTask
        inFlightOperation?.cancel()
        switch state {
        case .working(_, .unmounting), .working(_, .forceUnmounting), .working(_, .ejecting):
            await inFlightOperation?.value
        default:
            break
        }
    }

    private func clearWorkflow(_ id: UUID) {
        guard workflowID == id else { return }
        workflowID = nil
        pendingTarget = nil
        activeWorkflow = nil
        operationTask = nil
        diagnosisTask?.cancel()
        diagnosisTask = nil
        topologyValidationTask = nil
        latestTopologyGeneration = nil
        validatedTopologyGeneration = nil
        releaseWorkflowID = nil
        releaseTask = nil
        cancellationWorkflowID = nil
        retainedRecovery = nil
    }

    func dismissTerminalFailure() {
        guard workflowID == nil else { return }
        switch state {
        case .failed, .resolutionFailed:
            state = .idle
        default:
            break
        }
    }

    private func isCurrent(_ id: UUID) -> Bool {
        workflowID == id && Task.isCancelled == false
    }

    private func isCurrentAttempt(_ id: UUID, attempt: Int) -> Bool {
        isCurrent(id) && activeWorkflow?.attemptGeneration == attempt
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
    private(set) var operationPlan: DiskEjectOperationPlan
    private(set) var scopeGeneration: Int
    private(set) var hasObservedExternalUnmount = false
    private(set) var attemptGeneration = 0
    private var barrier: (any EjectBarrier)?

    init(
        id: UUID,
        target: EjectWorkflowTarget,
        scope: OccupancyTargetScope,
        operationPlan: DiskEjectOperationPlan,
        barrier: any EjectBarrier
    ) {
        self.id = id
        self.target = target
        self.scope = scope
        self.operationPlan = operationPlan
        self.scopeGeneration = target.topologyGeneration
        self.barrier = barrier
    }

    func refresh(_ resolved: ResolvedEjectTarget, generation: Int) {
        guard generation >= scopeGeneration else { return }
        let scope = resolved.scope
        if self.scope.mountURLs.isEmpty == false, scope.mountURLs.isEmpty {
            hasObservedExternalUnmount = true
        }
        self.scope = scope
        operationPlan = resolved.operationPlan
        scopeGeneration = generation
    }

    func beginNextAttempt() -> Int {
        attemptGeneration += 1
        return attemptGeneration
    }

    func takeBarrier() -> (any EjectBarrier)? {
        defer { barrier = nil }
        return barrier
    }
}
