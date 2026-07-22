import XCTest
@testable import DrivePulseApp

import DiskArbitration
import Foundation
import Synchronization

@MainActor
final class ExternalDeviceDiscoveryObservationTests: XCTestCase {
    func testStandaloneDeviceMonitorOwnsObservationLifecycle() {
        let monitoringSession = ObservationMonitoringSessionStub()
        let monitor = DiskArbitrationDeviceMonitor(
            monitoringSession: monitoringSession,
            sessionQueue: DispatchQueue(label: "DrivePulse.DeviceMonitorTests"),
            enumerateDevices: { [] }
        )

        let observation = monitor.observeDevices { _ in }

        XCTAssertTrue(monitoringSession.isActive)
        observation.cancel()
        XCTAssertFalse(monitoringSession.isActive)
        XCTAssertEqual(monitoringSession.deactivateCallCount, 1)
    }

    func testLastObserverStopReconcilesObserverRegisteredDuringDeactivation() {
        let monitoringSession = ObservationMonitoringSessionStub()
        let discovery = LiveExternalDeviceDiscovery(monitoringSession: monitoringSession)
        let firstObservation = discovery.observeDevices { _ in }
        let retainedObservation = Mutex<(any ExternalDeviceDiscoveryObservation)?>(nil)
        monitoringSession.onNextDeactivate {
            let observation = discovery.observeDevices { _ in }
            retainedObservation.withLock { $0 = observation }
        }

        firstObservation.cancel()

        XCTAssertTrue(monitoringSession.isActive)
        XCTAssertNotNil(retainedObservation.withLock { $0 })
    }

    func testCancellingOneOfMultipleObserversDoesNotDeactivateMonitoring() {
        let monitoringSession = ObservationMonitoringSessionStub()
        let discovery = LiveExternalDeviceDiscovery(monitoringSession: monitoringSession)
        let firstObservation = discovery.observeDevices { _ in }
        let secondObservation = discovery.observeDevices { _ in }

        firstObservation.cancel()

        XCTAssertTrue(monitoringSession.isActive)
        XCTAssertEqual(monitoringSession.deactivateCallCount, 0)
        secondObservation.cancel()
    }

    func testLastObserverCancellationDeactivatesExactlyOnce() {
        let monitoringSession = ObservationMonitoringSessionStub()
        let discovery = LiveExternalDeviceDiscovery(monitoringSession: monitoringSession)
        let observation = discovery.observeDevices { _ in }

        observation.cancel()
        observation.cancel()

        XCTAssertFalse(monitoringSession.isActive)
        XCTAssertEqual(monitoringSession.deactivateCallCount, 1)
    }

    func testRapidStopStartKeepsNewObserverActive() {
        let monitoringSession = ObservationMonitoringSessionStub()
        let discovery = LiveExternalDeviceDiscovery(monitoringSession: monitoringSession)
        let firstObservation = discovery.observeDevices { _ in }

        firstObservation.cancel()
        let secondObservation = discovery.observeDevices { _ in }

        XCTAssertTrue(monitoringSession.isActive)
        XCTAssertEqual(monitoringSession.activateCallCount, 2)
        secondObservation.cancel()
    }

    func testRepeatedStopStartRegistersCallbacksOnlyOnce() {
        let monitoringSession = ObservationMonitoringSessionStub()
        let discovery = LiveExternalDeviceDiscovery(monitoringSession: monitoringSession)

        for _ in 0..<3 {
            let observation = discovery.observeDevices { _ in }
            observation.cancel()
        }

        XCTAssertEqual(monitoringSession.callbackRegistrationCount, 1)
        XCTAssertEqual(monitoringSession.activateCallCount, 3)
        XCTAssertEqual(monitoringSession.deactivateCallCount, 3)
    }

    func testCancelledObserverDoesNotReceiveQueuedDiskEvent() async {
        let monitoringSession = ObservationMonitoringSessionStub()
        let discovery = LiveExternalDeviceDiscovery(monitoringSession: monitoringSession)
        var updateCount = 0
        let observation = discovery.observeDevices { _ in
            updateCount += 1
        }

        discovery.handleDiskEvent()
        observation.cancel()

        let mainActorDrain = expectation(description: "queued delivery drained")
        Task { @MainActor in
            mainActorDrain.fulfill()
        }
        await fulfillment(of: [mainActorDrain], timeout: 1)

        XCTAssertEqual(updateCount, 0)
    }

    func testDiscoveryDeinitDeactivatesActiveSession() {
        let monitoringSession = ObservationMonitoringSessionStub()
        var discovery: LiveExternalDeviceDiscovery? = LiveExternalDeviceDiscovery(
            monitoringSession: monitoringSession
        )
        let observation = discovery?.observeDevices { _ in }

        discovery = nil

        XCTAssertFalse(monitoringSession.isActive)
        XCTAssertEqual(monitoringSession.deactivateCallCount, 1)
        observation?.cancel()
    }
}

private final class ObservationMonitoringSessionStub: DiskArbitrationMonitoringSession, Sendable {
    private struct State {
        var activateCallCount = 0
        var deactivateCallCount = 0
        var callbackRegistrationCount = 0
        var isActive = false
        var onNextDeactivate: (@Sendable () -> Void)?
    }

    private let state = Mutex(State())

    var activateCallCount: Int {
        state.withLock(\.activateCallCount)
    }

    var deactivateCallCount: Int {
        state.withLock(\.deactivateCallCount)
    }

    var callbackRegistrationCount: Int {
        state.withLock(\.callbackRegistrationCount)
    }

    var isActive: Bool {
        state.withLock(\.isActive)
    }

    func onNextDeactivate(_ action: @escaping @Sendable () -> Void) {
        state.withLock { $0.onNextDeactivate = action }
    }

    func registerCallbacks(
        context: UnsafeMutableRawPointer,
        appearedCallback: @escaping DADiskAppearedCallback,
        disappearedCallback: @escaping DADiskDisappearedCallback,
        descriptionChangedCallback: @escaping DADiskDescriptionChangedCallback
    ) {
        _ = context
        _ = appearedCallback
        _ = disappearedCallback
        _ = descriptionChangedCallback
        state.withLock {
            $0.callbackRegistrationCount += 1
        }
    }

    func activate(on queue: DispatchQueue) {
        _ = queue
        state.withLock {
            $0.activateCallCount += 1
            $0.isActive = true
        }
    }

    func deactivate() {
        let action = state.withLock { state -> (@Sendable () -> Void)? in
            state.deactivateCallCount += 1
            let action = state.onNextDeactivate
            state.onNextDeactivate = nil
            return action
        }
        action?()
        state.withLock { $0.isActive = false }
    }
}
