import DiskArbitration
import Foundation

import DrivePulseCore

protocol DiskArbitrationMonitoringSession: Sendable {
    func registerCallbacks(
        context: UnsafeMutableRawPointer,
        appearedCallback: @escaping DADiskAppearedCallback,
        disappearedCallback: @escaping DADiskDisappearedCallback,
        descriptionChangedCallback: @escaping DADiskDescriptionChangedCallback
    )
    func registerEjectApprovalCallback(
        context: UnsafeMutableRawPointer,
        callback: @escaping DADiskEjectApprovalCallback
    )

    func activate(on queue: DispatchQueue)
    func deactivate()
}

final class DiskEjectIntentOriginTracker: @unchecked Sendable {
    static let shared = DiskEjectIntentOriginTracker()

    // Eject submission and approval callbacks run on different DA session queues.
    // The lock protects every access to the shared origin markers.
    private let lock = NSLock()
    private var ownIntentBSDNames: Set<String> = []

    func reserveOwnIntent(targetBSDName: String) {
        _ = lock.withLock {
            ownIntentBSDNames.insert(targetBSDName)
        }
    }

    func consumeOwnIntent(targetBSDName: String) -> Bool {
        lock.withLock {
            ownIntentBSDNames.remove(targetBSDName) != nil
        }
    }

    func discardOwnIntent(targetBSDName: String) {
        _ = lock.withLock {
            ownIntentBSDNames.remove(targetBSDName)
        }
    }
}

/// Owns the Disk Arbitration callback context and the complete observer lifecycle.
final class DiskArbitrationDeviceMonitor: @unchecked Sendable {
    private let monitoringSession: (any DiskArbitrationMonitoringSession)?
    private let sessionQueue: DispatchQueue
    private let enumerateDevices: @Sendable () -> [ExternalDevice]
    private let ejectIntentOriginTracker: DiskEjectIntentOriginTracker
    private let sessionQueueKey = DispatchSpecificKey<Void>()
    private var observers: [UUID: @MainActor ([ExternalDevice]) -> Void] = [:]
    private var ejectIntentObservers: [UUID: @MainActor (DiskEjectIntent) -> Void] = [:]
    private var callbackContext: UnsafeMutableRawPointer?
    private var callbacksRegistered = false
    private var isMonitoring = false
    private var isDeactivating = false

    init(
        monitoringSession: (any DiskArbitrationMonitoringSession)?,
        sessionQueue: DispatchQueue,
        enumerateDevices: @escaping @Sendable () -> [ExternalDevice],
        ejectIntentOriginTracker: DiskEjectIntentOriginTracker = .shared
    ) {
        self.monitoringSession = monitoringSession
        self.sessionQueue = sessionQueue
        self.enumerateDevices = enumerateDevices
        self.ejectIntentOriginTracker = ejectIntentOriginTracker
        self.sessionQueue.setSpecific(key: sessionQueueKey, value: ())
    }

    func observeDevices(
        _ onUpdate: @escaping @MainActor ([ExternalDevice]) -> Void
    ) -> any ExternalDeviceDiscoveryObservation {
        let observerID = UUID()

        performOnSessionQueue {
            observers[observerID] = onUpdate
            if observerCount == 1 {
                startMonitoringOnSessionQueue()
            }
        }

        return DiskArbitrationDeviceObservation { [weak self] in
            self?.removeDeviceObserver(observerID)
        }
    }

    func observeDiskEjectIntents(
        _ onIntent: @escaping @MainActor (DiskEjectIntent) -> Void
    ) -> any ExternalDeviceDiscoveryObservation {
        let observerID = UUID()

        performOnSessionQueue {
            ejectIntentObservers[observerID] = onIntent
            if observerCount == 1 {
                startMonitoringOnSessionQueue()
            }
        }

        return DiskArbitrationDeviceObservation { [weak self] in
            self?.removeEjectIntentObserver(observerID)
        }
    }

    deinit {
        let context: UnsafeMutableRawPointer?
        if DispatchQueue.getSpecific(key: sessionQueueKey) == nil {
            context = sessionQueue.sync {
                teardownOnSessionQueue()
            }
        } else {
            context = teardownOnSessionQueue()
            if let context {
                let rawContext = UInt(bitPattern: context)
                sessionQueue.async {
                    Self.releaseCallbackContext(rawContext)
                }
            }
        }

        if DispatchQueue.getSpecific(key: sessionQueueKey) == nil, let context {
            Self.releaseCallbackContext(UInt(bitPattern: context))
        }
    }

    func handleDiskEvent() {
        performOnSessionQueue {
            let devices = enumerateDevices()
            let observerIDs = Array(observers.keys)
            for observerID in observerIDs {
                deliver(devices, to: observerID)
            }
        }
    }

    func handleDiskEjectIntent(targetBSDName: String) {
        guard ejectIntentOriginTracker.consumeOwnIntent(targetBSDName: targetBSDName) == false else {
            return
        }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let intent = DiskEjectIntent(targetBSDName: targetBSDName)
            let observerIDs = Array(ejectIntentObservers.keys)
            for observerID in observerIDs {
                deliver(intent, to: observerID)
            }
        }
    }

    private static func releaseCallbackContext(_ rawContext: UInt) {
        guard let context = UnsafeMutableRawPointer(bitPattern: rawContext) else {
            return
        }

        Unmanaged<DiskArbitrationDeviceMonitorCallbackState>
            .fromOpaque(context)
            .release()
    }

    private func startMonitoringOnSessionQueue() {
        guard let monitoringSession else {
            return
        }

        guard isMonitoring == false, isDeactivating == false else {
            return
        }

        if callbackContext == nil {
            let callbackState = DiskArbitrationDeviceMonitorCallbackState(monitor: self)
            callbackContext = Unmanaged.passRetained(callbackState).toOpaque()
        }

        guard let callbackContext else {
            return
        }

        if callbacksRegistered == false {
            monitoringSession.registerCallbacks(
                context: callbackContext,
                appearedCallback: diskArbitrationDeviceAppearedCallback,
                disappearedCallback: diskArbitrationDeviceDisappearedCallback,
                descriptionChangedCallback: diskArbitrationDeviceDescriptionChangedCallback
            )
            monitoringSession.registerEjectApprovalCallback(
                context: callbackContext,
                callback: diskArbitrationDiskEjectApprovalCallback
            )
            callbacksRegistered = true
        }

        guard isMonitoring == false else {
            return
        }
        isMonitoring = true
        monitoringSession.activate(on: sessionQueue)
    }

    @discardableResult
    private func teardownOnSessionQueue() -> UnsafeMutableRawPointer? {
        isDeactivating = true
        if isMonitoring {
            isMonitoring = false
            monitoringSession?.deactivate()
        }
        isDeactivating = false

        let context = callbackContext
        callbackContext = nil
        if let context {
            Unmanaged<DiskArbitrationDeviceMonitorCallbackState>
                .fromOpaque(context)
                .takeUnretainedValue()
                .invalidate()
        }
        return context
    }

    private func stopMonitoringOnSessionQueue() {
        guard isMonitoring, observerCount == 0 else {
            return
        }

        isMonitoring = false
        isDeactivating = true
        monitoringSession?.deactivate()
        isDeactivating = false

        if observerCount > 0 {
            startMonitoringOnSessionQueue()
        }
    }

    private var observerCount: Int {
        observers.count + ejectIntentObservers.count
    }

    private func removeDeviceObserver(_ observerID: UUID) {
        performOnSessionQueue {
            observers.removeValue(forKey: observerID)
            stopMonitoringOnSessionQueue()
        }
    }

    private func removeEjectIntentObserver(_ observerID: UUID) {
        performOnSessionQueue {
            ejectIntentObservers.removeValue(forKey: observerID)
            stopMonitoringOnSessionQueue()
        }
    }

    private func performOnSessionQueue(_ operation: () -> Void) {
        if DispatchQueue.getSpecific(key: sessionQueueKey) == nil {
            sessionQueue.sync(execute: operation)
        } else {
            operation()
        }
    }

    private func deliver(_ devices: [ExternalDevice], to observerID: UUID) {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            var handler: (@MainActor ([ExternalDevice]) -> Void)?
            self.performOnSessionQueue {
                handler = self.observers[observerID]
            }
            handler?(devices)
        }
    }

    private func deliver(_ intent: DiskEjectIntent, to observerID: UUID) {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            var handler: (@MainActor (DiskEjectIntent) -> Void)?
            self.performOnSessionQueue {
                handler = self.ejectIntentObservers[observerID]
            }
            handler?(intent)
        }
    }
}

private final class DiskArbitrationDeviceObservation: ExternalDeviceDiscoveryObservation, @unchecked Sendable {
    private let onCancel: () -> Void
    private let lock = NSLock()
    private var didCancel = false

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }

        guard didCancel == false else {
            return
        }

        didCancel = true
        onCancel()
    }
}

private final class DiskArbitrationDeviceMonitorCallbackState: @unchecked Sendable {
    private let lock = NSLock()
    private weak var monitor: DiskArbitrationDeviceMonitor?
    private var isActive = true

    init(monitor: DiskArbitrationDeviceMonitor) {
        self.monitor = monitor
    }

    func invalidate() {
        lock.lock()
        isActive = false
        monitor = nil
        lock.unlock()
    }

    func handleDiskEvent() {
        lock.lock()
        let monitor = isActive ? monitor : nil
        lock.unlock()

        monitor?.handleDiskEvent()
    }

    func handleDiskEjectIntent(targetBSDName: String) {
        lock.lock()
        let monitor = isActive ? monitor : nil
        lock.unlock()

        monitor?.handleDiskEjectIntent(targetBSDName: targetBSDName)
    }
}

private let diskArbitrationDeviceAppearedCallback: DADiskAppearedCallback = { _, context in
    diskArbitrationDeviceMonitorCallbackState(from: context)?.handleDiskEvent()
}

private let diskArbitrationDeviceDisappearedCallback: DADiskDisappearedCallback = { _, context in
    diskArbitrationDeviceMonitorCallbackState(from: context)?.handleDiskEvent()
}

private let diskArbitrationDeviceDescriptionChangedCallback: DADiskDescriptionChangedCallback = { _, _, context in
    diskArbitrationDeviceMonitorCallbackState(from: context)?.handleDiskEvent()
}

private let diskArbitrationDiskEjectApprovalCallback: DADiskEjectApprovalCallback = { disk, context in
    let targetDisk = DADiskCopyWholeDisk(disk) ?? disk
    if let bsdName = DADiskGetBSDName(targetDisk) {
        diskArbitrationDeviceMonitorCallbackState(from: context)?.handleDiskEjectIntent(
            targetBSDName: String(cString: bsdName)
        )
    }
    return nil
}

private func diskArbitrationDeviceMonitorCallbackState(
    from context: UnsafeMutableRawPointer?
) -> DiskArbitrationDeviceMonitorCallbackState? {
    guard let context else {
        return nil
    }

    return Unmanaged<DiskArbitrationDeviceMonitorCallbackState>
        .fromOpaque(context)
        .takeUnretainedValue()
}

final class LiveDiskArbitrationMonitoringSession: DiskArbitrationMonitoringSession, @unchecked Sendable {
    private let session: DASession?
    private var callbacksRegistered = false

    init(session: DASession? = DASessionCreate(kCFAllocatorDefault)) {
        self.session = session
    }

    func registerCallbacks(
        context: UnsafeMutableRawPointer,
        appearedCallback: @escaping DADiskAppearedCallback,
        disappearedCallback: @escaping DADiskDisappearedCallback,
        descriptionChangedCallback: @escaping DADiskDescriptionChangedCallback
    ) {
        guard let session else {
            return
        }

        guard callbacksRegistered == false else {
            return
        }
        DARegisterDiskAppearedCallback(session, nil, appearedCallback, context)
        DARegisterDiskDisappearedCallback(session, nil, disappearedCallback, context)
        DARegisterDiskDescriptionChangedCallback(session, nil, nil, descriptionChangedCallback, context)
        callbacksRegistered = true
    }

    func registerEjectApprovalCallback(
        context: UnsafeMutableRawPointer,
        callback: @escaping DADiskEjectApprovalCallback
    ) {
        guard let session else {
            return
        }
        DARegisterDiskEjectApprovalCallback(session, nil, callback, context)
    }

    func activate(on queue: DispatchQueue) {
        guard let session else {
            return
        }

        DASessionSetDispatchQueue(session, queue)
    }

    func deactivate() {
        guard let session else {
            return
        }

        DASessionSetDispatchQueue(session, nil)
    }
}
