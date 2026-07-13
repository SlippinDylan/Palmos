import Combine
import Foundation

import DrivePulseCore

@MainActor
final class EjectCoordinator: ObservableObject {
    @Published private(set) var state: EjectWorkflowState = .idle

    private let resolver: any EjectTargetResolving
    private let quiescer: any DeviceIOQuiescing
    private let ejecter: any DiskEjecting
    private let occupancyScanner: any OccupancyScanning
    private let preparationTimeout: Duration

    private var workflowID: UUID?
    private var pendingTarget: EjectWorkflowTarget?
    private var activeWorkflow: ActiveWorkflow?
    private var operationTask: Task<Void, Never>?

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
        workflowID = id
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
        operationTask = Task { [weak self] in
            await self?.finishCancellation(workflowID: id)
        }
    }

    func retry() {
        guard case .awaitingRecovery = state,
              let activeWorkflow else { return }
        startOperation(workflowID: activeWorkflow.id) { [weak self] in
            await self?.revalidateAndPerformNormalEject(workflowID: activeWorkflow.id)
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
        guard case .awaitingForceConfirmation = state,
              let activeWorkflow else { return }
        startOperation(workflowID: activeWorkflow.id) { [weak self] in
            await self?.revalidateAndPerformForceEject(workflowID: activeWorkflow.id)
        }
    }

    func deviceTopologyDidChange(generation: Int) {
        guard let activeWorkflow else { return }
        startOperation(workflowID: activeWorkflow.id) { [weak self] in
            await self?.revalidateForTopologyChange(workflowID: activeWorkflow.id)
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
                clearWorkflow(id)
                state = .idle
            }
        }
    }

    private func revalidateAndPerformNormalEject(workflowID id: UUID) async {
        guard let workflow = activeWorkflow, workflow.id == id else { return }
        do {
            let refreshed = try await resolver.revalidate(workflow.target)
            guard isCurrent(id) else { return }
            workflow.scope = refreshed.scope
            state = .working(target: workflow.target, stage: .unmounting)
            let result = await ejecter.performNormalEject(bsdName: workflow.target.physicalBSDName)
            guard isCurrent(id) else { return }
            await handleNormalResult(result, workflow: workflow)
        } catch {
            await handleRevalidationError(error, target: workflow.target, workflowID: id)
        }
    }

    private func revalidateAndPerformForceEject(workflowID id: UUID) async {
        guard let workflow = activeWorkflow, workflow.id == id else { return }
        do {
            let refreshed = try await resolver.revalidate(workflow.target)
            guard isCurrent(id) else { return }
            workflow.scope = refreshed.scope
            state = .working(target: workflow.target, stage: .forceUnmounting)
            let result = await ejecter.performConfirmedForceEject(bsdName: workflow.target.physicalBSDName)
            guard isCurrent(id) else { return }
            switch result {
            case .success:
                await finishSuccess(workflow: workflow)
            case .failure(let failure):
                await finishFailure(failure, target: workflow.target, workflowID: id)
            }
        } catch {
            await handleRevalidationError(error, target: workflow.target, workflowID: id)
        }
    }

    private func revalidateForTopologyChange(workflowID id: UUID) async {
        guard let workflow = activeWorkflow, workflow.id == id else { return }
        do {
            let refreshed = try await resolver.revalidate(workflow.target)
            guard isCurrent(id) else { return }
            workflow.scope = refreshed.scope
        } catch {
            await handleRevalidationError(error, target: workflow.target, workflowID: id)
        }
    }

    private func handleNormalResult(
        _ result: Result<Void, EjectFailure>,
        workflow: ActiveWorkflow
    ) async {
        switch result {
        case .success:
            await finishSuccess(workflow: workflow)
        case .failure(let failure) where failure.category == .busy && failure.stage == .unmounting:
            state = .working(target: workflow.target, stage: .diagnosingOccupancy)
            let scan = await occupancyScanner.scan(workflowID: workflow.id, scope: workflow.scope)
            guard isCurrent(workflow.id) else { return }
            var diagnosedFailure = failure
            diagnosedFailure.holders = scan.holders
            state = .awaitingRecovery(.init(
                target: workflow.target,
                failure: diagnosedFailure,
                holders: scan.holders
            ))
        case .failure(let failure):
            await finishFailure(failure, target: workflow.target, workflowID: workflow.id)
        }
    }

    private func handleRevalidationError(
        _ error: Error,
        target: EjectWorkflowTarget,
        workflowID id: UUID
    ) async {
        guard isCurrent(id) else { return }
        if isDisappearance(error) {
            await releaseBarrier(workflowID: id)
            state = .disappeared(target)
            clearWorkflow(id)
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

    private func finishSuccess(workflow: ActiveWorkflow) async {
        await releaseBarrier(workflowID: workflow.id)
        state = .succeeded(workflow.target)
        clearWorkflow(workflow.id)
    }

    private func finishFailure(
        _ failure: EjectFailure,
        target: EjectWorkflowTarget,
        workflowID id: UUID
    ) async {
        await releaseBarrier(workflowID: id)
        state = .failed(target: target, failure: failure)
        clearWorkflow(id)
    }

    private func finishCancellation(workflowID id: UUID) async {
        guard isCurrent(id) else { return }
        await releaseBarrier(workflowID: id)
        state = .idle
        clearWorkflow(id)
    }

    private func releaseBarrier(workflowID id: UUID) async {
        guard let workflow = activeWorkflow, workflow.id == id else { return }
        activeWorkflow = nil
        await workflow.barrier.release()
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
    }

    private func isCurrent(_ id: UUID) -> Bool {
        workflowID == id && Task.isCancelled == false
    }

    private func isDisappearance(_ error: Error) -> Bool {
        guard let error = error as? EjectTargetResolutionError else { return false }
        return error == .deviceNotFound || error == .targetChanged
    }

    private func preparationFailure(
        _ error: DeviceIOQuiescenceError,
        target: EjectWorkflowTarget
    ) -> EjectFailure {
        EjectFailure(
            stage: .preparing,
            category: error == .timedOut ? .timedOut : .unknown,
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
    let barrier: any EjectBarrier

    init(
        id: UUID,
        target: EjectWorkflowTarget,
        scope: OccupancyTargetScope,
        barrier: any EjectBarrier
    ) {
        self.id = id
        self.target = target
        self.scope = scope
        self.barrier = barrier
    }
}
