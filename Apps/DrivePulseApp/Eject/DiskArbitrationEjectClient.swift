@preconcurrency import DiskArbitration
import Foundation

protocol DiskArbitrationOperating: Sendable {
    func unmountWhole(_ bsdName: String, force: Bool) async -> DiskArbitrationOperationResult
    func eject(_ bsdName: String) async -> DiskArbitrationOperationResult
}

protocol DiskEjecting: Sendable {
    func performNormalEject(bsdName: String) async -> Result<Void, EjectFailure>
    func performConfirmedForceEject(bsdName: String) async -> Result<Void, EjectFailure>
}

enum DiskArbitrationOperationResult: Equatable, Sendable {
    case success
    case failure(status: DAReturn, message: String?)
    case timedOut
    case cancelled
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

    func performNormalEject(bsdName: String) async -> Result<Void, EjectFailure> {
        await performEject(bsdName: bsdName, force: false)
    }

    func performConfirmedForceEject(bsdName: String) async -> Result<Void, EjectFailure> {
        await performEject(bsdName: bsdName, force: true)
    }

    private func performEject(bsdName: String, force: Bool) async -> Result<Void, EjectFailure> {
        let unmountStage: EjectOperationStage = force ? .forceUnmounting : .unmounting
        let unmountResult = await operations.unmountWhole(bsdName, force: force)

        if case .failure(let status, _) = unmountResult,
           classifier.classify(status) == .notMounted {
            // An already-unmounted whole disk is ready for the eject phase.
        } else if let failure = failure(from: unmountResult, stage: unmountStage, bsdName: bsdName) {
            return .failure(failure)
        }

        let ejectResult = await operations.eject(bsdName)
        if let failure = failure(from: ejectResult, stage: .ejecting, bsdName: bsdName) {
            return .failure(failure)
        }
        return .success(())
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
        label: "DrivePulse.DiskArbitrationEjectClient",
        qos: .userInitiated
    )
    private let timeoutNanoseconds: UInt64

    init(timeoutNanoseconds: UInt64 = 10_000_000_000) {
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    func unmountWhole(_ bsdName: String, force: Bool) async -> DiskArbitrationOperationResult {
        await perform(bsdName: bsdName) { disk, context in
            var options = DADiskUnmountOptions(kDADiskUnmountOptionWhole)
            if force {
                options |= DADiskUnmountOptions(kDADiskUnmountOptionForce)
            }
            DADiskUnmount(disk, options, diskArbitrationUnmountCallback, context)
        }
    }

    func eject(_ bsdName: String) async -> DiskArbitrationOperationResult {
        await perform(bsdName: bsdName) { disk, context in
            DADiskEject(disk, DADiskEjectOptions(kDADiskEjectOptionDefault), diskArbitrationEjectCallback, context)
        }
    }

    private func perform(
        bsdName: String,
        operation: @escaping @Sendable (DADisk, UnsafeMutableRawPointer) -> Void
    ) async -> DiskArbitrationOperationResult {
        let cancellation = DiskArbitrationOperationCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<DiskArbitrationOperationResult, Never>) in
                sessionQueue.async { [sessionQueue, timeoutNanoseconds] in
                    guard let session = DASessionCreate(kCFAllocatorDefault),
                          let disk = bsdName.withCString({
                              DADiskCreateFromBSDName(kCFAllocatorDefault, session, $0)
                          }) else {
                        continuation.resume(returning: .failure(
                            status: DAReturn(kDAReturnNotFound), message: nil
                        ))
                        return
                    }

                    DASessionSetDispatchQueue(session, sessionQueue)
                    let context = DiskArbitrationCallbackRegistry.shared.register(resume: { result in
                        continuation.resume(returning: result)
                    }, cleanup: {
                        DASessionSetDispatchQueue(session, nil)
                    })
                    cancellation.install(context)
                    operation(disk, context)

                    Task {
                        try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                        DiskArbitrationCallbackRegistry.shared.resolve(context: context, event: .timeout)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

final class DiskArbitrationOperationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private let registry: DiskArbitrationCallbackRegistry
    private var context: UnsafeMutableRawPointer?
    private var isCancelled = false

    init(registry: DiskArbitrationCallbackRegistry = .shared) {
        self.registry = registry
    }

    func install(_ context: UnsafeMutableRawPointer) {
        let shouldCancel = lock.withLock {
            self.context = context
            return isCancelled
        }
        if shouldCancel {
            registry.resolve(context: context, event: .cancelled)
        }
    }

    func cancel() {
        let installedContext = lock.withLock {
            isCancelled = true
            return self.context
        }
        if let context = installedContext {
            registry.resolve(context: context, event: .cancelled)
        }
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
    private var entries: [UInt: Entry] = [:]
    private var cleanupObserver: (@Sendable (UInt) -> Void)?

    private struct Entry {
        let completion: DiskArbitrationOperationCompletion
        let context: UnsafeMutableRawPointer
        let cleanup: @Sendable () -> Void
    }

    init(cleanupObserver: (@Sendable (UInt) -> Void)? = nil) {
        self.cleanupObserver = cleanupObserver
    }

    func register(
        resume: @escaping @Sendable (DiskArbitrationOperationResult) -> Void,
        cleanup: @escaping @Sendable () -> Void = {}
    ) -> UnsafeMutableRawPointer {
        let context = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        let key = UInt(bitPattern: context)
        let completion = DiskArbitrationOperationCompletion(resume: resume)
        lock.withLock { entries[key] = Entry(completion: completion, context: context, cleanup: cleanup) }
        return context
    }

    func resolve(context: UnsafeMutableRawPointer?, event: DiskArbitrationOperationCompletion.Event) {
        guard let context else { return }
        let completion = lock.withLock { entries[UInt(bitPattern: context)]?.completion }
        completion?.resolve(event)
    }

    func resolveCallback(context: UnsafeMutableRawPointer?, result: DiskArbitrationOperationResult) {
        guard let context else { return }
        let key = UInt(bitPattern: context)
        let entry = lock.withLock { entries.removeValue(forKey: key) }
        guard let entry else { return }
        entry.completion.resolve(.callback(result))
        entry.cleanup()
        entry.context.deallocate()
        cleanupObserver?(key)
    }

    var registeredContextCount: Int {
        lock.withLock { entries.count }
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
