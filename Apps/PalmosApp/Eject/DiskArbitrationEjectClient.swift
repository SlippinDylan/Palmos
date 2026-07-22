@preconcurrency import DiskArbitration
import Foundation
import IOKit

protocol DiskArbitrationOperating: Sendable {
    func performWholeDiskEject(
        plan: DiskEjectOperationPlan,
        force: Bool
    ) async -> DiskArbitrationSequenceResult
}

protocol DiskEjecting: Sendable {
    func performNormalEject(plan: DiskEjectOperationPlan) async -> DiskEjectOutcome
    func performConfirmedForceEject(plan: DiskEjectOperationPlan) async -> DiskEjectOutcome
}

enum DiskArbitrationOperationResult: Equatable, Sendable {
    case success
    case failure(status: DAReturn, message: String?)
    case timedOut
    case cancelled
}

enum DiskArbitrationSequenceResult: Equatable, Sendable {
    case success
    case failure(result: DiskArbitrationOperationResult, stage: EjectOperationStage)
    case targetInvalidated(stage: EjectOperationStage)
}

struct BoundDiskArbitrationSecondStageGate {
    enum Transition: Equatable {
        case ejectSubmitted
        case finished(DiskArbitrationSequenceResult)
    }

    let targetIsValid: () -> Bool
    let submitEject: () -> Void

    func proceedAfterUnmount(
        _ result: DiskArbitrationOperationResult,
        stage: EjectOperationStage
    ) -> Transition {
        switch result {
        case .success:
            break
        case .failure(let status, _)
            where DiskArbitrationErrorClassifier().classify(status) == .notMounted:
            break
        default:
            return .finished(.failure(result: result, stage: stage))
        }

        guard targetIsValid() else {
            return .finished(.targetInvalidated(stage: .ejecting))
        }
        submitEject()
        return .ejectSubmitted
    }
}

/// Absorbs one transient logical-unmount busy result without releasing the
/// workflow barrier or weakening the bound physical/logical identity checks.
struct BoundDiskArbitrationLogicalUnmountRetryGate {
    enum Transition: Equatable {
        case retryScheduled
        case finished(DiskArbitrationSequenceResult)
    }

    let prepareRetry: @Sendable () -> Void
    let scheduleRetry: @Sendable (@escaping @Sendable () -> Void) -> Void
    let targetIsValid: @Sendable () -> Bool
    let submitRetry: @Sendable () -> Void
    let finish: @Sendable (DiskArbitrationSequenceResult) -> Void

    func proceedAfterFailedUnmount(
        _ result: DiskArbitrationOperationResult,
        stage: EjectOperationStage,
        force: Bool,
        hasRetried: Bool
    ) -> Transition {
        guard force == false,
              hasRetried == false,
              case .failure(let status, _) = result,
              DiskArbitrationErrorClassifier().classify(status) == .busy else {
            return .finished(.failure(result: result, stage: stage))
        }

        prepareRetry()
        scheduleRetry {
            guard targetIsValid() else {
                finish(.targetInvalidated(stage: stage))
                return
            }
            submitRetry()
        }
        return .retryScheduled
    }
}

struct DiskArbitrationEjectClient: DiskEjecting {
    private let operations: any DiskArbitrationOperating
    private let classifier: DiskArbitrationErrorClassifier

    init(
        operations: any DiskArbitrationOperating = LiveDiskArbitrationOperating(),
        classifier: DiskArbitrationErrorClassifier = DiskArbitrationErrorClassifier()
    ) {
        self.operations = operations
        self.classifier = classifier
    }

    func performNormalEject(plan: DiskEjectOperationPlan) async -> DiskEjectOutcome {
        map(
            await operations.performWholeDiskEject(plan: plan, force: false),
            target: plan.physicalTarget
        )
    }

    func performConfirmedForceEject(plan: DiskEjectOperationPlan) async -> DiskEjectOutcome {
        map(
            await operations.performWholeDiskEject(plan: plan, force: true),
            target: plan.physicalTarget
        )
    }

    func performNormalEject(
        target: PhysicalDiskTargetIdentity,
        scope: OccupancyTargetScope
    ) async -> DiskEjectOutcome {
        _ = scope
        return await performNormalEject(plan: DiskEjectOperationPlan(physicalTarget: target))
    }

    func performConfirmedForceEject(target: PhysicalDiskTargetIdentity) async -> DiskEjectOutcome {
        await performConfirmedForceEject(plan: DiskEjectOperationPlan(physicalTarget: target))
    }

    private func map(
        _ result: DiskArbitrationSequenceResult,
        target: PhysicalDiskTargetIdentity
    ) -> DiskEjectOutcome {
        switch result {
        case .success:
            return .success
        case .targetInvalidated(let stage):
            return .targetInvalidated(stage: stage)
        case .failure(let result, let stage):
            if let failure = failure(from: result, stage: stage, bsdName: target.bsdName) {
                return .failure(failure)
            }
            return .failure(EjectFailure(
                stage: stage,
                category: .unknown,
                rawStatus: nil,
                systemMessage: "Disk Arbitration returned an invalid success state",
                physicalBSDName: target.bsdName,
                holders: []
            ))
        }
    }

    private func failure(
        from result: DiskArbitrationOperationResult,
        stage: EjectOperationStage,
        bsdName: String
    ) -> EjectFailure? {
        switch result {
        case .success:
            return nil
        case .failure(let status, let message):
            return EjectFailure(
                stage: stage,
                category: classifier.classify(status),
                rawStatus: status,
                systemMessage: message,
                physicalBSDName: bsdName,
                holders: []
            )
        case .timedOut:
            return EjectFailure(
                stage: stage,
                category: .timedOut,
                rawStatus: nil,
                systemMessage: nil,
                physicalBSDName: bsdName,
                holders: []
            )
        case .cancelled:
            return EjectFailure(
                stage: stage,
                category: .unknown,
                rawStatus: nil,
                systemMessage: nil,
                physicalBSDName: bsdName,
                holders: []
            )
        }
    }

}

final class LiveDiskArbitrationOperating: DiskArbitrationOperating, @unchecked Sendable {
    private let sessionQueue = DispatchQueue(
        label: "Palmos.DiskArbitrationEjectClient",
        qos: .userInitiated
    )
    private let timeoutNanoseconds: UInt64
    private let logicalUnmountRetryDelayNanoseconds: UInt64
    private let ejectIntentOriginTracker: DiskEjectIntentOriginTracker

    init(
        timeoutNanoseconds: UInt64 = 10_000_000_000,
        logicalUnmountRetryDelayNanoseconds: UInt64 = 300_000_000,
        ejectIntentOriginTracker: DiskEjectIntentOriginTracker = .shared
    ) {
        self.timeoutNanoseconds = timeoutNanoseconds
        self.logicalUnmountRetryDelayNanoseconds = logicalUnmountRetryDelayNanoseconds
        self.ejectIntentOriginTracker = ejectIntentOriginTracker
    }

    func performWholeDiskEject(
        plan: DiskEjectOperationPlan,
        force: Bool
    ) async -> DiskArbitrationSequenceResult {
        let cancellation = DiskArbitrationOperationCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<DiskArbitrationSequenceResult, Never>) in
                sessionQueue.async { [
                    sessionQueue,
                    timeoutNanoseconds,
                    logicalUnmountRetryDelayNanoseconds,
                    ejectIntentOriginTracker
                ] in
                    guard let session = DASessionCreate(kCFAllocatorDefault),
                          let physicalDisk = plan.physicalTarget.bsdName.withCString({
                              DADiskCreateFromBSDName(kCFAllocatorDefault, session, $0)
                          }) else {
                        continuation.resume(returning: .failure(
                            result: .failure(status: DAReturn(kDAReturnNotFound), message: nil),
                            stage: force ? .forceUnmounting : .unmounting
                        ))
                        return
                    }

                    let logicalDisks = plan.logicalWholeDiskTargets.compactMap { identity in
                        identity.bsdName.withCString {
                            DADiskCreateFromBSDName(kCFAllocatorDefault, session, $0)
                        }.map { (identity, $0) }
                    }
                    guard logicalDisks.count == plan.logicalWholeDiskTargets.count else {
                        continuation.resume(returning: .failure(
                            result: .failure(status: DAReturn(kDAReturnNotFound), message: nil),
                            stage: force ? .forceUnmounting : .unmounting
                        ))
                        return
                    }

                    DASessionSetDispatchQueue(session, sessionQueue)
                    let sequence = LiveDiskArbitrationBoundSequence(
                        session: session,
                        physicalDisk: physicalDisk,
                        plan: plan,
                        logicalDisks: logicalDisks,
                        force: force,
                        sessionQueue: sessionQueue,
                        timeoutNanoseconds: timeoutNanoseconds,
                        logicalUnmountRetryDelayNanoseconds: logicalUnmountRetryDelayNanoseconds,
                        ejectIntentOriginTracker: ejectIntentOriginTracker,
                        cancellation: cancellation,
                        continuation: continuation
                    )
                    sequence.start()
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

private enum BoundDiskArbitrationPhase: Sendable {
    case logicalUnmount(Int)
    case physicalUnmount
    case physicalEject

    func operationStage(force: Bool) -> EjectOperationStage {
        switch self {
        case .logicalUnmount, .physicalUnmount:
            force ? .forceUnmounting : .unmounting
        case .physicalEject:
            .ejecting
        }
    }
}

/// Queue-confined wrapper for one freshly resolved leaf-to-root DA plan.
private final class LiveDiskArbitrationBoundSequence: @unchecked Sendable {
    private let session: DASession
    private let physicalDisk: DADisk
    private let plan: DiskEjectOperationPlan
    private let logicalDisks: [(identity: DiskArbitrationWholeDiskIdentity, disk: DADisk)]
    private let force: Bool
    private let sessionQueue: DispatchQueue
    private let timeoutNanoseconds: UInt64
    private let logicalUnmountRetryDelayNanoseconds: UInt64
    private let ejectIntentOriginTracker: DiskEjectIntentOriginTracker
    private let cancellation: DiskArbitrationOperationCancellation
    private let continuation: CheckedContinuation<DiskArbitrationSequenceResult, Never>
    private let lock = NSLock()
    private var finished = false
    private var hasRetriedLogicalUnmount = false
    private var reservedEjectBSDNames: Set<String> = []

    init(
        session: DASession,
        physicalDisk: DADisk,
        plan: DiskEjectOperationPlan,
        logicalDisks: [(DiskArbitrationWholeDiskIdentity, DADisk)],
        force: Bool,
        sessionQueue: DispatchQueue,
        timeoutNanoseconds: UInt64,
        logicalUnmountRetryDelayNanoseconds: UInt64,
        ejectIntentOriginTracker: DiskEjectIntentOriginTracker,
        cancellation: DiskArbitrationOperationCancellation,
        continuation: CheckedContinuation<DiskArbitrationSequenceResult, Never>
    ) {
        self.session = session
        self.physicalDisk = physicalDisk
        self.plan = plan
        self.logicalDisks = logicalDisks
        self.force = force
        self.sessionQueue = sessionQueue
        self.timeoutNanoseconds = timeoutNanoseconds
        self.logicalUnmountRetryDelayNanoseconds = logicalUnmountRetryDelayNanoseconds
        self.ejectIntentOriginTracker = ejectIntentOriginTracker
        self.cancellation = cancellation
        self.continuation = continuation
    }

    func start() {
        guard physicalTargetMatches(), logicalTargetsMatch() else {
            finish(.targetInvalidated(stage: force ? .forceUnmounting : .unmounting))
            return
        }
        if logicalDisks.isEmpty {
            submitPhysicalUnmount()
        } else {
            submitLogicalUnmount(at: 0)
        }
    }

    private func submitLogicalUnmount(at index: Int) {
        guard physicalTargetMatches(), targetMatches(logicalDisks[index]) else {
            finish(.targetInvalidated(stage: force ? .forceUnmounting : .unmounting))
            return
        }
        let disk = logicalDisks[index].disk
        submit(phase: .logicalUnmount(index)) { [disk, force] token in
            var options = DADiskUnmountOptions(kDADiskUnmountOptionWhole)
            if force { options |= DADiskUnmountOptions(kDADiskUnmountOptionForce) }
            DADiskUnmount(disk, options, diskArbitrationUnmountCallback, token.unsafeContext)
        }
    }

    private func submitPhysicalUnmount() {
        guard physicalTargetMatches() else {
            finish(.targetInvalidated(stage: force ? .forceUnmounting : .unmounting))
            return
        }
        submit(phase: .physicalUnmount) { [physicalDisk, force] token in
            var options = DADiskUnmountOptions(kDADiskUnmountOptionWhole)
            if force { options |= DADiskUnmountOptions(kDADiskUnmountOptionForce) }
            DADiskUnmount(physicalDisk, options, diskArbitrationUnmountCallback, token.unsafeContext)
        }
    }

    private func submitPhysicalEject() {
        guard physicalTargetMatches() else {
            finish(.targetInvalidated(stage: .ejecting))
            return
        }
        reserveOwnEjectIntent(plan.physicalTarget.bsdName)
        submit(phase: .physicalEject) { [physicalDisk] token in
            DADiskEject(
                physicalDisk,
                DADiskEjectOptions(kDADiskEjectOptionDefault),
                diskArbitrationEjectCallback,
                token.unsafeContext
            )
        }
    }

    private func submit(
        phase: BoundDiskArbitrationPhase,
        operation: @escaping @Sendable (DiskArbitrationCallbackToken) -> Void
    ) {
        let queue = sessionQueue
        let sequence = self
        let token = DiskArbitrationCallbackRegistry.shared.register(
            resume: { result in
                queue.async {
                    sequence.handle(result, phase: phase)
                }
            }
        )
        cancellation.install(token)
        guard cancellation.submit({ operation(token) }) else { return }
        sessionQueue.asyncAfter(deadline: .now() + .nanoseconds(Int(timeoutNanoseconds))) {
            DiskArbitrationCallbackRegistry.shared.resolve(context: token, event: .timeout)
        }
    }

    private func handle(_ result: DiskArbitrationOperationResult, phase: BoundDiskArbitrationPhase) {
        let stage = phase.operationStage(force: force)
        switch phase {
        case .logicalUnmount(let index):
            guard unmountSucceeded(result) else {
                handleFailedLogicalUnmount(result, index: index, stage: stage)
                return
            }
            continueToNextStage {
                let nextIndex = index + 1
                if logicalDisks.indices.contains(nextIndex) {
                    submitLogicalUnmount(at: nextIndex)
                } else {
                    submitPhysicalUnmount()
                }
            }
        case .physicalUnmount:
            guard unmountSucceeded(result) else {
                finish(.failure(result: result, stage: stage))
                return
            }
            continueToNextStage { submitPhysicalEject() }
        case .physicalEject:
            result == .success
                ? finish(.success)
                : finish(.failure(result: result, stage: stage))
        }
    }

    private func handleFailedLogicalUnmount(
        _ result: DiskArbitrationOperationResult,
        index: Int,
        stage: EjectOperationStage
    ) {
        let sequence = self
        let gate = BoundDiskArbitrationLogicalUnmountRetryGate(
            prepareRetry: cancellation.prepareNextStage,
            scheduleRetry: { [sessionQueue, logicalUnmountRetryDelayNanoseconds] retry in
                sessionQueue.asyncAfter(
                    deadline: .now() + .nanoseconds(Int(logicalUnmountRetryDelayNanoseconds)),
                    execute: retry
                )
            },
            targetIsValid: {
                sequence.physicalTargetMatches() && sequence.targetMatches(sequence.logicalDisks[index])
            },
            submitRetry: { sequence.submitLogicalUnmount(at: index) },
            finish: sequence.finish
        )

        switch gate.proceedAfterFailedUnmount(
            result,
            stage: stage,
            force: force,
            hasRetried: hasRetriedLogicalUnmount
        ) {
        case .retryScheduled:
            hasRetriedLogicalUnmount = true
        case .finished(let result):
            finish(result)
        }
    }

    private func continueToNextStage(_ operation: () -> Void) {
        cancellation.prepareNextStage()
        operation()
    }

    private func unmountSucceeded(_ result: DiskArbitrationOperationResult) -> Bool {
        switch result {
        case .success:
            true
        case .failure(let status, _):
            DiskArbitrationErrorClassifier().classify(status) == .notMounted
        case .timedOut, .cancelled:
            false
        }
    }

    private func reserveOwnEjectIntent(_ bsdName: String) {
        reservedEjectBSDNames.insert(bsdName)
        ejectIntentOriginTracker.reserveOwnIntent(targetBSDName: bsdName)
    }

    private func finish(_ result: DiskArbitrationSequenceResult) {
        let shouldResume = lock.withLock {
            guard finished == false else { return false }
            finished = true
            return true
        }
        guard shouldResume else { return }
        for bsdName in reservedEjectBSDNames {
            ejectIntentOriginTracker.discardOwnIntent(targetBSDName: bsdName)
        }
        DASessionSetDispatchQueue(session, nil)
        continuation.resume(returning: result)
    }

    private func logicalTargetsMatch() -> Bool {
        logicalDisks.allSatisfy(targetMatches)
    }

    private func targetMatches(
        _ target: (identity: DiskArbitrationWholeDiskIdentity, disk: DADisk)
    ) -> Bool {
        guard let wholeDisk = DADiskCopyWholeDisk(target.disk),
              let wholeName = DADiskGetBSDName(wholeDisk),
              String(cString: wholeName) == target.identity.bsdName else {
            return false
        }
        let ioMedia = DADiskCopyIOMedia(target.disk)
        guard ioMedia != IO_OBJECT_NULL else { return false }
        var registryEntryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(ioMedia, &registryEntryID) == KERN_SUCCESS,
              registryEntryID == target.identity.mediaRegistryEntryID,
              let description = DADiskCopyDescription(target.disk) as NSDictionary? else {
            return false
        }
        let isWhole = description[kDADiskDescriptionMediaWholeKey] as? Bool ?? false
        return isWhole
    }

    private func physicalTargetMatches() -> Bool {
        guard let wholeDisk = DADiskCopyWholeDisk(physicalDisk),
              let wholeName = DADiskGetBSDName(wholeDisk),
              String(cString: wholeName) == plan.physicalTarget.bsdName else {
            return false
        }
        let ioMedia = DADiskCopyIOMedia(physicalDisk)
        guard ioMedia != IO_OBJECT_NULL else { return false }
        var registryEntryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(ioMedia, &registryEntryID) == KERN_SUCCESS,
              registryEntryID == plan.physicalTarget.mediaRegistryEntryID,
              let description = DADiskCopyDescription(physicalDisk) as NSDictionary? else {
            return false
        }
        let isWhole = description[kDADiskDescriptionMediaWholeKey] as? Bool ?? false
        let isInternal = description[kDADiskDescriptionDeviceInternalKey] as? Bool ?? true
        let isNetwork = description[kDADiskDescriptionVolumeNetworkKey] as? Bool ?? true
        return isWhole && isInternal == false && isNetwork == false
    }
}

final class DiskArbitrationOperationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private let registry: DiskArbitrationCallbackRegistry
    private var callbackToken: DiskArbitrationCallbackToken?
    private var isCancelled = false
    private var isSubmitted = false

    init(registry: DiskArbitrationCallbackRegistry = .shared) {
        self.registry = registry
    }

    func install(_ callbackToken: DiskArbitrationCallbackToken) {
        let shouldCancel = lock.withLock {
            self.callbackToken = callbackToken
            return isCancelled
        }
        if shouldCancel {
            registry.resolve(context: callbackToken, event: .cancelled)
        }
    }

    func cancel() {
        let installedToken = lock.withLock {
            isCancelled = true
            return callbackToken
        }
        if let installedToken {
            registry.resolve(context: installedToken, event: .cancelled)
        }
    }

    func submit(_ operation: @Sendable () -> Void) -> Bool {
        lock.withLock {
            guard isCancelled == false, isSubmitted == false else { return false }
            isSubmitted = true
            operation()
            return true
        }
    }

    func prepareNextStage() {
        lock.withLock {
            callbackToken = nil
            isSubmitted = false
        }
    }
}

struct DiskArbitrationCallbackToken: Hashable, Sendable {
    let rawValue: UInt

    init(rawValue: UInt) {
        precondition(rawValue != 0, "Disk Arbitration callback token must be nonzero")
        self.rawValue = rawValue
    }

    init?(unsafeContext: UnsafeMutableRawPointer?) {
        guard let unsafeContext else { return nil }
        let rawValue = UInt(bitPattern: unsafeContext)
        guard rawValue != 0 else { return nil }
        self.rawValue = rawValue
    }

    var unsafeContext: UnsafeMutableRawPointer? {
        UnsafeMutableRawPointer(bitPattern: rawValue)
    }
}

final class DiskArbitrationOperationCompletion: @unchecked Sendable {
    enum Event: Sendable {
        case callback(DiskArbitrationOperationResult)
        case timeout
        case cancelled
    }

    private let lock = NSLock()
    private var isResolved = false
    private let resume: @Sendable (DiskArbitrationOperationResult) -> Void

    init(resume: @escaping @Sendable (DiskArbitrationOperationResult) -> Void) {
        self.resume = resume
    }

    func resolve(_ event: Event) {
        let result: DiskArbitrationOperationResult = switch event {
        case .callback(let result): result
        case .timeout: .timedOut
        case .cancelled: .cancelled
        }

        let won = lock.withLock {
            guard isResolved == false else { return false }
            isResolved = true
            return true
        }
        guard won else { return }
        resume(result)
    }
}

final class DiskArbitrationCallbackRegistry: @unchecked Sendable {
    static let shared = DiskArbitrationCallbackRegistry()

    private let lock = NSLock()
    private var entries: [DiskArbitrationCallbackToken: Entry] = [:]
    private var nextToken: UInt = 1
    private var cleanupObserver: (@Sendable (UInt) -> Void)?

    private struct Entry {
        let completion: DiskArbitrationOperationCompletion
        let cleanup: @Sendable () -> Void
    }

    init(cleanupObserver: (@Sendable (UInt) -> Void)? = nil) {
        self.cleanupObserver = cleanupObserver
    }

    func register(
        resume: @escaping @Sendable (DiskArbitrationOperationResult) -> Void,
        cleanup: @escaping @Sendable () -> Void = {}
    ) -> DiskArbitrationCallbackToken {
        let completion = DiskArbitrationOperationCompletion(resume: resume)
        return lock.withLock {
            let token = DiskArbitrationCallbackToken(rawValue: nextToken)
            nextToken &+= 1
            entries[token] = Entry(completion: completion, cleanup: cleanup)
            return token
        }
    }

    func resolve(
        context callbackToken: DiskArbitrationCallbackToken,
        event: DiskArbitrationOperationCompletion.Event
    ) {
        resolveTerminal(callbackToken: callbackToken, event: event)
    }

    func resolveCallback(
        context callbackToken: DiskArbitrationCallbackToken,
        result: DiskArbitrationOperationResult
    ) {
        resolveTerminal(callbackToken: callbackToken, event: .callback(result))
    }

    func resolveCallback(
        context unsafeContext: UnsafeMutableRawPointer?,
        result: DiskArbitrationOperationResult
    ) {
        guard let callbackToken = DiskArbitrationCallbackToken(unsafeContext: unsafeContext) else {
            return
        }
        resolveCallback(context: callbackToken, result: result)
    }

    var registeredContextCount: Int {
        lock.withLock { entries.count }
    }

    private func resolveTerminal(
        callbackToken: DiskArbitrationCallbackToken,
        event: DiskArbitrationOperationCompletion.Event
    ) {
        let entry = lock.withLock { entries.removeValue(forKey: callbackToken) }
        guard let entry else { return }
        entry.completion.resolve(event)
        entry.cleanup()
        cleanupObserver?(callbackToken.rawValue)
    }
}

private let diskArbitrationUnmountCallback: DADiskUnmountCallback = { _, dissenter, context in
    completeDiskArbitrationOperation(dissenter: dissenter, context: context)
}

private let diskArbitrationEjectCallback: DADiskEjectCallback = { _, dissenter, context in
    completeDiskArbitrationOperation(dissenter: dissenter, context: context)
}

private func completeDiskArbitrationOperation(dissenter: DADissenter?, context: UnsafeMutableRawPointer?) {
    let result: DiskArbitrationOperationResult
    if let dissenter {
        result = .failure(
            status: DADissenterGetStatus(dissenter),
            message: DADissenterGetStatusString(dissenter) as String?
        )
    } else {
        result = .success
    }
    DiskArbitrationCallbackRegistry.shared.resolveCallback(context: context, result: result)
}
