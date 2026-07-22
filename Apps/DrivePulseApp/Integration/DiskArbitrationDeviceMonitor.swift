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

    func activate(on queue: DispatchQueue)
    func deactivate()
}

/// Owns the Disk Arbitration callback context and the complete observer lifecycle.
final class DiskArbitrationDeviceMonitor: @unchecked Sendable {
    private let monitoringSession: (any DiskArbitrationMonitoringSession)?
    private let sessionQueue: DispatchQueue
    private let enumerateDevices: @Sendable () -> [ExternalDevice]
    private let sessionQueueKey = DispatchSpecificKey<Void>()
    private var observers: [UUID: @MainActor ([ExternalDevice]) -> Void] = [:]
    private var callbackContext: UnsafeMutableRawPointer?
    private var callbacksRegistered = false
    private var isMonitoring = false
    private var isDeactivating = false

    init(
        monitoringSession: (any DiskArbitrationMonitoringSession)?,
        sessionQueue: DispatchQueue,
        enumerateDevices: @escaping @Sendable () -> [ExternalDevice]
    ) {
        self.monitoringSession = monitoringSession
        self.sessionQueue = sessionQueue
        self.enumerateDevices = enumerateDevices
        self.sessionQueue.setSpecific(key: sessionQueueKey, value: ())
    }

    func observeDevices(
        _ onUpdate: @escaping @MainActor ([ExternalDevice]) -> Void
    ) -> any ExternalDeviceDiscoveryObservation {
        let observerID = UUID()

        performOnSessionQueue {
            observers[observerID] = onUpdate
            if observers.count == 1 {
                startMonitoringOnSessionQueue()
            }
        }

        return DiskArbitrationDeviceObservation { [weak self] in
            self?.removeObserver(observerID)
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
        guard isMonitoring, observers.isEmpty else {
            return
        }

        isMonitoring = false
        isDeactivating = true
        monitoringSession?.deactivate()
        isDeactivating = false

        if observers.isEmpty == false {
            startMonitoringOnSessionQueue()
        }
    }

    private func removeObserver(_ observerID: UUID) {
        performOnSessionQueue {
            observers.removeValue(forKey: observerID)
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
