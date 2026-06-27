import XCTest
@testable import DrivePulseApp

import DiskArbitration
import Foundation
import DrivePulseCore

@MainActor
final class DrivePulseAppControllerTests: XCTestCase {
    func testControllerBootstrapsStateFromDiscoveryAsynchronously() async {
        let discoveredDevices = [
            makeDevice(id: "disk21", volumes: ["disk21s1"])
        ]
        let discovery = StubExternalDeviceDiscovery(results: [discoveredDevices])

        let controller = DrivePulseAppController(deviceDiscovery: discovery)

        XCTAssertEqual(controller.state.devices, [])
        let initialInvocationCount = await discovery.invocationCountSnapshot()
        XCTAssertEqual(initialInvocationCount, 0)

        await discovery.resolveNextDiscovery()
        await waitUntilStateDevices(
            controller,
            equals: discoveredDevices
        )

        XCTAssertEqual(controller.state.devices, discoveredDevices)
        XCTAssertEqual(controller.state.selectedDeviceID, DeviceID(rawValue: "disk21"))
        let bootstrapInvocationCount = await discovery.invocationCountSnapshot()
        XCTAssertEqual(bootstrapInvocationCount, 1)
    }

    func testRefreshRequeriesDiscoveryAndReplacesDevicesAsynchronously() async {
        let initialDevices = [
            makeDevice(id: "disk21", volumes: ["disk21s1"])
        ]
        let refreshedDevices = [
            makeDevice(id: "disk42", volumes: []),
            makeDevice(id: "disk84", volumes: ["disk84s2"])
        ]
        let discovery = StubExternalDeviceDiscovery(results: [initialDevices, refreshedDevices])
        let controller = DrivePulseAppController(deviceDiscovery: discovery)

        await discovery.resolveNextDiscovery()
        await waitUntilStateDevices(
            controller,
            equals: initialDevices
        )

        controller.refresh()

        XCTAssertEqual(controller.state.devices, initialDevices)

        await discovery.resolveNextDiscovery()
        await waitUntilStateDevices(
            controller,
            equals: refreshedDevices
        )

        XCTAssertEqual(controller.state.devices, refreshedDevices)
        XCTAssertEqual(controller.state.selectedDeviceID, DeviceID(rawValue: "disk42"))
        let refreshInvocationCount = await discovery.invocationCountSnapshot()
        XCTAssertEqual(refreshInvocationCount, 2)
    }

    func testControllerSubscribesToDiscoveryStreamAndAppliesUpdates() {
        let initialDevices = [
            makeDevice(id: "disk21", volumes: ["disk21s1"])
        ]
        let discovery = StubExternalDeviceDiscovery(results: [initialDevices])
        let controller = DrivePulseAppController(deviceDiscovery: discovery)
        let updatedDevices = [
            makeDevice(id: "disk84", volumes: []),
            makeDevice(id: "disk126", volumes: ["disk126s1"])
        ]

        discovery.emit(updatedDevices)

        XCTAssertEqual(discovery.subscriptionCount, 1)
        XCTAssertEqual(controller.state.devices, updatedDevices)
        XCTAssertEqual(controller.state.selectedDeviceID, DeviceID(rawValue: "disk84"))
    }

    func testControllerCancelsDiscoveryObservationOnDeinit() {
        let discovery = StubExternalDeviceDiscovery(results: [[makeDevice(id: "disk21", volumes: [])]])
        var controller: DrivePulseAppController? = DrivePulseAppController(deviceDiscovery: discovery)

        XCTAssertEqual(discovery.cancellationCount, 0)

        controller = nil

        XCTAssertNil(controller)
        XCTAssertEqual(discovery.cancellationCount, 1)
    }

    func testPerformRunsActionAsynchronouslyAndPublishesFailureFeedback() async {
        let actionPerformer = StubSystemActionPerformer()
        let controller = DrivePulseAppController(
            systemActions: actionPerformer,
            deviceDiscovery: StubExternalDeviceDiscovery(results: [[makeDevice(id: "disk21", volumes: [])]])
        )
        let action = SystemAction(kind: .eject, intent: .ejectPhysicalDevice(bsdName: "disk21"))

        controller.perform(action)

        XCTAssertNil(controller.actionFeedback)
        await actionPerformer.waitUntilStarted()
        let performedActions = await actionPerformer.performedActionsSnapshot()
        XCTAssertEqual(performedActions, [action])

        await actionPerformer.finish(
            with: TestActionError.failed(message: "Action couldn't be completed.")
        )

        let feedbackExpectation = expectation(description: "feedback updated")
        Task { @MainActor in
            while controller.actionFeedback == nil {
                await Task.yield()
            }

            feedbackExpectation.fulfill()
        }

        await fulfillment(of: [feedbackExpectation], timeout: 1.0)
        XCTAssertEqual(controller.actionFeedback, "Action couldn't be completed.")
    }

    func testDiscoveryObservationCancelStopsMonitoringWhenLastObserverIsRemoved() {
        let monitoringSession = StubDiskArbitrationMonitoringSession()
        let discovery = LiveExternalDeviceDiscovery(monitoringSession: monitoringSession)

        let observation = discovery.observeDevices { _ in }

        XCTAssertEqual(monitoringSession.activateCallCount, 1)
        XCTAssertEqual(monitoringSession.deactivateCallCount, 0)

        observation.cancel()

        XCTAssertEqual(monitoringSession.deactivateCallCount, 1)
    }

    func testDiscoveryKeepsMonitoringActiveWhileAnotherObserverExists() {
        let monitoringSession = StubDiskArbitrationMonitoringSession()
        let discovery = LiveExternalDeviceDiscovery(monitoringSession: monitoringSession)

        let firstObservation = discovery.observeDevices { _ in }
        let secondObservation = discovery.observeDevices { _ in }

        firstObservation.cancel()

        XCTAssertEqual(monitoringSession.activateCallCount, 1)
        XCTAssertEqual(monitoringSession.deactivateCallCount, 0)

        secondObservation.cancel()

        XCTAssertEqual(monitoringSession.deactivateCallCount, 1)
    }

    private func makeDevice(id rawID: String, volumes: [String]) -> ExternalDevice {
        ExternalDevice(
            id: DeviceID(rawValue: rawID),
            displayName: "Device \(rawID)",
            transportName: "USB",
            smartSnapshot: .notRequested,
            sessionMetrics: .empty(historyLimit: 0),
            physicalStoreBSDName: rawID,
            apfsContainerBSDName: nil,
            volumes: volumes.map(MountedVolume.init(bsdName:))
        )
    }

    private func waitUntilStateDevices(
        _ controller: DrivePulseAppController,
        equals devices: [ExternalDevice]
    ) async {
        while controller.state.devices != devices {
            await Task.yield()
        }
    }
}

private final class StubExternalDeviceDiscovery: ExternalDeviceDiscovering, @unchecked Sendable {
    private let state: State
    private(set) var subscriptionCount = 0
    private(set) var cancellationCount = 0
    private var onUpdate: (@MainActor @Sendable ([ExternalDevice]) -> Void)?

    init(results: [[ExternalDevice]]) {
        self.state = State(results: results)
    }

    func discoverDevices() async -> [ExternalDevice] {
        await state.discoverDevices()
    }

    func observeDevices(
        _ onUpdate: @escaping @MainActor @Sendable ([ExternalDevice]) -> Void
    ) -> any ExternalDeviceDiscoveryObservation {
        subscriptionCount += 1
        self.onUpdate = onUpdate
        return StubExternalDeviceDiscoveryObservation { [weak self] in
            self?.cancellationCount += 1
        }
    }

    @MainActor
    func emit(_ devices: [ExternalDevice]) {
        onUpdate?(devices)
    }

    func resolveNextDiscovery() async {
        await state.resolveNextDiscovery()
    }

    func invocationCountSnapshot() async -> Int {
        await state.invocationCountSnapshot()
    }

    private actor State {
        private let results: [[ExternalDevice]]
        private var invocationCount = 0
        private var pendingContinuations: [CheckedContinuation<Void, Never>] = []

        init(results: [[ExternalDevice]]) {
            self.results = results
        }

        func discoverDevices() async -> [ExternalDevice] {
            await withCheckedContinuation { continuation in
                pendingContinuations.append(continuation)
            }

            defer { invocationCount += 1 }

            let index = min(invocationCount, results.count - 1)
            return results[index]
        }

        func resolveNextDiscovery() async {
            while pendingContinuations.isEmpty {
                await Task.yield()
            }

            let continuation = pendingContinuations.removeFirst()
            continuation.resume()
        }

        func invocationCountSnapshot() -> Int {
            invocationCount
        }
    }
}

private final class StubExternalDeviceDiscoveryObservation: ExternalDeviceDiscoveryObservation, @unchecked Sendable {
    private let onCancel: @Sendable () -> Void
    private let lock = NSLock()
    private var didCancel = false

    init(onCancel: @escaping @Sendable () -> Void) {
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

private actor StubSystemActionPerformer: SystemActionPerforming {
    private var continuation: CheckedContinuation<Void, Error>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private(set) var performedActions: [SystemAction] = []
    private var didStart = false

    func perform(_ action: SystemAction) async throws {
        performedActions.append(action)
        didStart = true
        startedContinuation?.resume()
        startedContinuation = nil

        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilStarted() async {
        if didStart {
            return
        }

        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    func finish(with error: Error? = nil) {
        guard let continuation else {
            return
        }

        self.continuation = nil

        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }

    func performedActionsSnapshot() -> [SystemAction] {
        performedActions
    }
}

private enum TestActionError: LocalizedError {
    case failed(message: String)

    var errorDescription: String? {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

private final class StubDiskArbitrationMonitoringSession: DiskArbitrationMonitoringSession, @unchecked Sendable {
    private(set) var activateCallCount = 0
    private(set) var deactivateCallCount = 0

    func activate(
        on queue: DispatchQueue,
        context: UnsafeMutableRawPointer,
        appearedCallback: @escaping DADiskAppearedCallback,
        disappearedCallback: @escaping DADiskDisappearedCallback,
        descriptionChangedCallback: @escaping DADiskDescriptionChangedCallback
    ) {
        _ = queue
        _ = context
        _ = appearedCallback
        _ = disappearedCallback
        _ = descriptionChangedCallback
        activateCallCount += 1
    }

    func deactivate() {
        deactivateCallCount += 1
    }
}
