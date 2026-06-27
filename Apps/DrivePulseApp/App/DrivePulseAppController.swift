import AppKit
import SwiftUI

import DrivePulseCore

@MainActor
final class DrivePulseAppController: ObservableObject {
    @Published private(set) var state: DrivePulseAppState
    @Published private(set) var actionFeedback: String?

    let settings: AppSettings
    let launchAtLoginController: LaunchAtLoginController

    private var discoveryObservation: (any ExternalDeviceDiscoveryObservation)?
    private let deviceDiscovery: any ExternalDeviceDiscovering
    private let systemActions: SystemActions

    init(
        state: DrivePulseAppState? = nil,
        settings: AppSettings = AppSettings(),
        launchAtLoginController: LaunchAtLoginController = LaunchAtLoginController(),
        systemActions: SystemActions = SystemActions(),
        deviceDiscovery: any ExternalDeviceDiscovering = LiveExternalDeviceDiscovery()
    ) {
        self.settings = settings
        self.launchAtLoginController = launchAtLoginController
        self.deviceDiscovery = deviceDiscovery
        self.systemActions = systemActions
        self.state = state ?? DrivePulseAppState(
            devices: deviceDiscovery.discoverDevices(),
            selectedDeviceID: nil
        )
        self.discoveryObservation = deviceDiscovery.observeDevices { [weak self] devices in
            self?.state.replaceDevices(devices)
        }
    }

    func selectDevice(_ id: DeviceID?) {
        state.selectDevice(id)
    }

    var selectedDeviceActions: [SystemAction] {
        SystemAction.actions(for: state.selectedDevice)
    }

    func perform(_ action: SystemAction) {
        do {
            try systemActions.perform(action)
            actionFeedback = nil
        } catch {
            actionFeedback = error.localizedDescription
        }
    }

    func refresh() {
        state.replaceDevices(deviceDiscovery.discoverDevices())
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }
}
