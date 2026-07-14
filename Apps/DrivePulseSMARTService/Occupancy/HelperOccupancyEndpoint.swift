import Foundation

struct HelperOccupancyEndpointResult: @unchecked Sendable {
    let data: Data?
    let error: NSError?
}

actor HelperOccupancyEndpoint {
    private struct ActiveRequest {
        let generation: UInt64
        let workflowID: UUID
        let physicalDeviceBSDName: String
        let cancellation: HelperOperationCancellation
    }

    private let snapshotProvider: HelperAuthoritativeSnapshotProvider
    private let scanner: HelperOccupancyScanner
    private let timeout: Duration
    private var nextGeneration: UInt64 = 0
    private var active: ActiveRequest?

    init(
        snapshotProvider: HelperAuthoritativeSnapshotProvider = HelperAuthoritativeSnapshotProvider(),
        scanner: HelperOccupancyScanner = HelperOccupancyScanner(),
        timeout: Duration = .seconds(3)
    ) {
        self.snapshotProvider = snapshotProvider
        self.scanner = scanner
        self.timeout = timeout
    }

    func handle(_ requestData: Data) async -> HelperOccupancyEndpointResult {
        let request: OccupancyScanRequest
        do {
            try HelperOccupancyRequestValidator.validateRequestBytes(requestData)
            request = try DrivePulseXPCMessages.decodeOccupancyRequest(from: requestData)
            try HelperOccupancyRequestValidator.validateBSDName(request.physicalDeviceBSDName)
        } catch {
            return failure(.invalidRequest)
        }

        if let active {
            guard active.workflowID == request.workflowID,
                  active.physicalDeviceBSDName == request.physicalDeviceBSDName else {
                return failure(.helperBusy)
            }
            active.cancellation.cancel()
            return encode(.incomplete, workflowID: request.workflowID)
        }

        nextGeneration &+= 1
        let generation = nextGeneration
        let cancellation = HelperOperationCancellation()
        active = ActiveRequest(
            generation: generation,
            workflowID: request.workflowID,
            physicalDeviceBSDName: request.physicalDeviceBSDName,
            cancellation: cancellation
        )

        let deadline = ContinuousClock.now.advanced(by: timeout)
        let operation = Task { [snapshotProvider, scanner] in
            do {
                let scope = try await snapshotProvider.scope(
                    for: request.physicalDeviceBSDName,
                    deadline: deadline,
                    cancellation: cancellation
                )
                guard !cancellation.isCancelled, ContinuousClock.now < deadline else {
                    return EndpointOperationOutcome.incomplete
                }
                let response = try await scanner.scan(
                    workflowID: request.workflowID,
                    scope: scope,
                    deadline: deadline,
                    externalCancellation: cancellation
                )
                guard !cancellation.isCancelled, ContinuousClock.now < deadline else {
                    return EndpointOperationOutcome.incomplete
                }
                return .response(response)
            } catch let error as HelperOccupancyError {
                return .failure(error)
            } catch {
                return cancellation.isCancelled ? .incomplete : .failure(.scanFailed)
            }
        }
        Task { [weak self] in
            _ = await operation.value
            await self?.operationDidFinish(generation: generation)
        }

        let outcome = await race(operation: operation, deadline: deadline, cancellation: cancellation)
        return encode(outcome, workflowID: request.workflowID)
    }

    private func operationDidFinish(generation: UInt64) {
        if active?.generation == generation { active = nil }
    }

    private func race(
        operation: Task<EndpointOperationOutcome, Never>,
        deadline: ContinuousClock.Instant,
        cancellation: HelperOperationCancellation
    ) async -> EndpointOperationOutcome {
        await withCheckedContinuation { continuation in
            let gate = EndpointRaceGate(continuation)
            Task {
                gate.resolve(await operation.value)
            }
            let timeoutTask = Task {
                do {
                    try await ContinuousClock().sleep(until: deadline)
                } catch {
                    return
                }
                cancellation.cancel()
                operation.cancel()
                gate.resolve(.incomplete)
            }
            gate.track(timeoutTask: timeoutTask)
        }
    }

    private func encode(
        _ outcome: EndpointOperationOutcome,
        workflowID: UUID
    ) -> HelperOccupancyEndpointResult {
        do {
            switch outcome {
            case let .response(response):
                return HelperOccupancyEndpointResult(
                    data: try DrivePulseXPCMessages.encodeOccupancyResponse(response),
                    error: nil
                )
            case .incomplete:
                return HelperOccupancyEndpointResult(
                    data: try DrivePulseXPCMessages.encodeOccupancyResponse(
                        OccupancyScanResponse(workflowID: workflowID, holders: [], isComplete: false)
                    ),
                    error: nil
                )
            case let .failure(error):
                return failure(error)
            }
        } catch {
            return failure(.scanFailed)
        }
    }

    private func failure(_ error: HelperOccupancyError) -> HelperOccupancyEndpointResult {
        HelperOccupancyEndpointResult(data: nil, error: error.nsError)
    }
}

private enum EndpointOperationOutcome: Sendable {
    case response(OccupancyScanResponse)
    case incomplete
    case failure(HelperOccupancyError)
}

private final class EndpointRaceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<EndpointOperationOutcome, Never>?
    private var timeoutTask: Task<Void, Never>?
    init(_ continuation: CheckedContinuation<EndpointOperationOutcome, Never>) {
        self.continuation = continuation
    }
    func track(timeoutTask: Task<Void, Never>) {
        let shouldCancel = lock.withLock { () -> Bool in
            guard continuation != nil else { return true }
            self.timeoutTask = timeoutTask
            return false
        }
        if shouldCancel { timeoutTask.cancel() }
    }
    func resolve(_ outcome: EndpointOperationOutcome) {
        let (pending, timeout) = lock.withLock { () -> (CheckedContinuation<EndpointOperationOutcome, Never>?, Task<Void, Never>?) in
            defer { continuation = nil }
            defer { timeoutTask = nil }
            return (continuation, timeoutTask)
        }
        timeout?.cancel()
        pending?.resume(returning: outcome)
    }
}
