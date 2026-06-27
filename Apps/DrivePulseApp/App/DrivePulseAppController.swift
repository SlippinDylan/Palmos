import AppKit
import SwiftUI

import DrivePulseCore

@MainActor
final class DrivePulseAppController: ObservableObject {
    @Published private(set) var state: DrivePulseAppState
    @Published private(set) var actionFeedback: String?
    @Published private(set) var isPerformingSystemAction = false

    let settings: AppSettings
    let launchAtLoginController: LaunchAtLoginController

    private var discoveryObservation: (any ExternalDeviceDiscoveryObservation)?
    private var discoveryLoadTask: Task<Void, Never>?
    private let deviceDiscovery: any ExternalDeviceDiscovering
    private let systemActions: any SystemActionPerforming

    init(
        state: DrivePulseAppState? = nil,
        settings: AppSettings = AppSettings(),
        launchAtLoginController: LaunchAtLoginController = LaunchAtLoginController(),
        systemActions: any SystemActionPerforming = SystemActions(),
        deviceDiscovery: any ExternalDeviceDiscovering = LiveExternalDeviceDiscovery()
    ) {
        self.settings = settings
        self.launchAtLoginController = launchAtLoginController
        self.deviceDiscovery = deviceDiscovery
        self.systemActions = systemActions
        self.state = state ?? DrivePulseAppState(
            devices: [],
            selectedDeviceID: nil
        )
        self.discoveryObservation = deviceDiscovery.observeDevices { [weak self] devices in
            self?.state.replaceDevices(devices)
        }

        if state == nil {
            loadDiscoveredDevices()
        }
    }

    deinit {
        discoveryLoadTask?.cancel()
        discoveryObservation?.cancel()
    }

    func selectDevice(_ id: DeviceID?) {
        state.selectDevice(id)
    }

    var selectedDeviceActions: [SystemAction] {
        SystemAction.actions(for: state.selectedDevice)
    }

    func perform(_ action: SystemAction) {
        guard isPerformingSystemAction == false else {
            return
        }

        isPerformingSystemAction = true
        actionFeedback = nil
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            do {
                try await systemActions.perform(action)
            } catch {
                actionFeedback = error.localizedDescription
            }

            isPerformingSystemAction = false
        }
    }

    func refresh() {
        loadDiscoveredDevices()
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func loadDiscoveredDevices() {
        discoveryLoadTask?.cancel()
        let deviceDiscovery = deviceDiscovery
        discoveryLoadTask = Task { [weak self] in
            let devices = await deviceDiscovery.discoverDevices()
            guard Task.isCancelled == false else {
                return
            }

            self?.state.replaceDevices(devices)
        }
    }
}
