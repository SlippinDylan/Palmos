import DiskArbitration
import Foundation

import DrivePulseCore

protocol ExternalDeviceDiscoveryObservation: Sendable {
    func cancel()
}

protocol ExternalDeviceDiscovering: Sendable {
    func discoverDevices() async -> [ExternalDevice]
    func observeDevices(
        _ onUpdate: @escaping @MainActor ([ExternalDevice]) -> Void
    ) -> any ExternalDeviceDiscoveryObservation
}

/// App-facing discovery façade. Enumeration, mapping, and monitoring own their
/// respective system resources in dedicated components.
final class LiveExternalDeviceDiscovery: ExternalDeviceDiscovering, @unchecked Sendable {
    private let sessionQueue: DispatchQueue
    private let enumerateDevicesOnSessionQueue: @Sendable () -> [ExternalDevice]
    private let monitor: DiskArbitrationDeviceMonitor

    init(
        mapper: ExternalDeviceDiscoveryMapper = ExternalDeviceDiscoveryMapper(
            identityRegistry: .shared
        ),
        monitoringSession: (any DiskArbitrationMonitoringSession)? = LiveDiskArbitrationMonitoringSession(),
        sessionQueue: DispatchQueue = DispatchQueue(label: "DrivePulse.ExternalDeviceDiscovery")
    ) {
        let enumerateDevices: @Sendable () -> [ExternalDevice] = {
            guard let session = DASessionCreate(kCFAllocatorDefault) else {
                return []
            }

            return mapper.map(DiskDiscoveryEnumerator(session: session).records())
        }

        self.sessionQueue = sessionQueue
        self.enumerateDevicesOnSessionQueue = enumerateDevices
        self.monitor = DiskArbitrationDeviceMonitor(
            monitoringSession: monitoringSession,
            sessionQueue: sessionQueue,
            enumerateDevices: enumerateDevices
        )
    }

    func discoverDevices() async -> [ExternalDevice] {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [enumerateDevicesOnSessionQueue] in
                continuation.resume(returning: enumerateDevicesOnSessionQueue())
            }
        }
    }

    func observeDevices(
        _ onUpdate: @escaping @MainActor ([ExternalDevice]) -> Void
    ) -> any ExternalDeviceDiscoveryObservation {
        monitor.observeDevices(onUpdate)
    }

    func handleDiskEvent() {
        monitor.handleDiskEvent()
    }
}
