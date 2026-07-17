import AppKit
@preconcurrency import DiskArbitration
import Darwin
import Foundation

protocol DiskArbitrationOperating: Sendable {
    func unmountWhole(_ bsdName: String, force: Bool) async -> DiskArbitrationOperationResult
    func eject(_ bsdName: String) async -> DiskArbitrationOperationResult
}

protocol VolumeUnmounting: Sendable {
    func unmountVolume(at url: URL, options: FileManager.UnmountOptions) async -> (any Error)?
}

protocol DissentingProcessIdentifying: Sendable {
    func holder(for pid: Int32) -> OccupancyHolder
}

protocol DiskEjecting: Sendable {
    func performNormalEject(
        bsdName: String,
        scope: OccupancyTargetScope
    ) async -> Result<Void, EjectFailure>
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
    private let volumeUnmounter: any VolumeUnmounting
    private let dissentingProcessIdentifier: any DissentingProcessIdentifying
    private let classifier: DiskArbitrationErrorClassifier

    init(
        operations: any DiskArbitrationOperating = LiveDiskArbitrationOperating(),
        volumeUnmounter: any VolumeUnmounting = LiveVolumeUnmounter(),
        dissentingProcessIdentifier: any DissentingProcessIdentifying = LiveDissentingProcessIdentifier(),
        classifier: DiskArbitrationErrorClassifier = DiskArbitrationErrorClassifier()
    ) {
        self.operations = operations
        self.volumeUnmounter = volumeUnmounter
        self.dissentingProcessIdentifier = dissentingProcessIdentifier
        self.classifier = classifier
    }

    func performNormalEject(
        bsdName: String,
        scope: OccupancyTargetScope
    ) async -> Result<Void, EjectFailure> {
        guard let mountURL = scope.mountURLs.sorted(by: { $0.path < $1.path }).first else {
            return await performPhysicalEject(bsdName: bsdName)
        }

        let error = await volumeUnmounter.unmountVolume(
            at: mountURL,
            options: [.allPartitionsAndEjectDisk, .withoutUI]
        )
        guard let error else { return .success(()) }
        return .failure(failure(from: error as NSError, bsdName: bsdName))
    }

    func performConfirmedForceEject(bsdName: String) async -> Result<Void, EjectFailure> {
        let unmountResult = await operations.unmountWhole(bsdName, force: true)

        if case .failure(let status, _) = unmountResult,
           classifier.classify(status) == .notMounted {
            // An already-unmounted whole disk is ready for the eject phase.
        } else if let failure = failure(from: unmountResult, stage: .forceUnmounting, bsdName: bsdName) {
            return .failure(failure)
        }

        return await performPhysicalEject(bsdName: bsdName)
    }

    private func performPhysicalEject(bsdName: String) async -> Result<Void, EjectFailure> {
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

    private func failure(from error: NSError, bsdName: String) -> EjectFailure {
        let pid = dissentingProcessPID(from: error)
        return EjectFailure(
            stage: .unmounting,
            category: pid == nil ? category(from: error) : .busy,
            rawStatus: Int32(exactly: error.code),
            systemMessage: error.localizedDescription,
            physicalBSDName: bsdName,
            holders: pid.map { [dissentingProcessIdentifier.holder(for: $0)] } ?? []
        )
    }

    private func category(from error: NSError) -> EjectFailureCategory {
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            let underlyingCategory = category(from: underlying)
            if underlyingCategory != .unknown { return underlyingCategory }
        }

        if error.domain == NSCocoaErrorDomain {
            return switch error.code {
            case CocoaError.fileNoSuchFile.rawValue: .notFound
            case CocoaError.fileReadNoPermission.rawValue,
                 CocoaError.fileWriteNoPermission.rawValue: .notPermitted
            case CocoaError.fileReadUnknown.rawValue,
                 CocoaError.fileWriteUnknown.rawValue: .io
            default: .unknown
            }
        }

        guard error.domain == NSPOSIXErrorDomain else { return .unknown }
        return switch Int32(error.code) {
        case EBUSY: .busy
        case EACCES, EPERM: .notPermitted
        case ENOENT, ENODEV: .notFound
        case ENXIO: .notReady
        case EIO: .io
        case ETIMEDOUT: .timedOut
        default: .unknown
        }
    }

    private func dissentingProcessPID(from error: NSError) -> Int32? {
        guard let number = error.userInfo[NSFileManagerUnmountDissentingProcessIdentifierErrorKey] as? NSNumber else {
            return nil
        }
        return Int32(exactly: number.int64Value)
    }
}

final class LiveVolumeUnmounter: VolumeUnmounting, @unchecked Sendable {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func unmountVolume(at url: URL, options: FileManager.UnmountOptions) async -> (any Error)? {
        await withCheckedContinuation { continuation in
            fileManager.unmountVolume(at: url, options: options) { error in
                continuation.resume(returning: error)
            }
        }
    }
}

struct LiveDissentingProcessIdentifier: DissentingProcessIdentifying {
    func holder(for pid: Int32) -> OccupancyHolder {
        let displayName = NSRunningApplication(processIdentifier: pid)?.localizedName
        return OccupancyHolder(
            pid: pid,
            executableName: executableName(for: pid) ?? displayName ?? "Process \(pid)",
            displayName: displayName,
            type: .unknown
        )
    }

    private func executableName(for pid: Int32) -> String? {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        let bytes = path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self)).lastPathComponent
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
        await perform(bsdName: bsdName) { disk, callbackToken in
            var options = DADiskUnmountOptions(kDADiskUnmountOptionWhole)
            if force {
                options |= DADiskUnmountOptions(kDADiskUnmountOptionForce)
            }
            DADiskUnmount(
                disk,
                options,
                diskArbitrationUnmountCallback,
                callbackToken.unsafeContext
            )
        }
    }

    func eject(_ bsdName: String) async -> DiskArbitrationOperationResult {
        await perform(bsdName: bsdName) { disk, callbackToken in
            DADiskEject(
                disk,
                DADiskEjectOptions(kDADiskEjectOptionDefault),
                diskArbitrationEjectCallback,
                callbackToken.unsafeContext
            )
        }
    }

    private func perform(
        bsdName: String,
        operation: @escaping @Sendable (DADisk, DiskArbitrationCallbackToken) -> Void
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
                    let callbackToken = DiskArbitrationCallbackRegistry.shared.register(resume: { result in
                        continuation.resume(returning: result)
                    }, cleanup: {
                        DASessionSetDispatchQueue(session, nil)
                    })
                    cancellation.install(callbackToken)
                    let submitted = cancellation.submit {
                        operation(disk, callbackToken)
                    }

                    guard submitted else { return }
                    Task {
                        try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                        DiskArbitrationCallbackRegistry.shared.resolve(
                            context: callbackToken,
                            event: .timeout
                        )
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
