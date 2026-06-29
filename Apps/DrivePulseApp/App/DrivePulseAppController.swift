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
    private var discoveryWriteGeneration = 0
    private let deviceDiscovery: any ExternalDeviceDiscovering
    private let smartService: any SMARTServiceProviding
    private let helperInstaller: any HelperInstalling
    private let systemActions: any SystemActionPerforming

    init(
        state: DrivePulseAppState? = nil,
        settings: AppSettings = AppSettings(),
        launchAtLoginController: LaunchAtLoginController = LaunchAtLoginController(),
        systemActions: any SystemActionPerforming = SystemActions(),
        smartService: any SMARTServiceProviding = SMARTServiceClient(),
        helperInstaller: any HelperInstalling = HelperInstaller(),
        deviceDiscovery: any ExternalDeviceDiscovering = LiveExternalDeviceDiscovery()
    ) {
        self.settings = settings
        self.launchAtLoginController = launchAtLoginController
        self.deviceDiscovery = deviceDiscovery
        self.smartService = smartService
        self.helperInstaller = helperInstaller
        self.systemActions = systemActions
        self.state = state ?? DrivePulseAppState(
            devices: [],
            selectedDeviceID: nil
        )
        self.discoveryObservation = deviceDiscovery.observeDevices { [weak self] devices in
            self?.applyObservedDevices(devices)
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
        let previousSelection = state.selectedDeviceID
        state.selectDevice(id)
        if state.selectedDeviceID != previousSelection {
            state.dismissSMARTPrompts()
        }
    }

    func refreshSelectedDeviceSMART() {
        guard let device = state.selectedDevice else {
            return
        }
        let deviceID = device.id
        guard state.smartDetails(for: deviceID)?.isRefreshing != true else {
            return
        }

        state.setSMARTRefreshing(for: deviceID)
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            let result = await smartService.refreshSMART(for: device)
            applySMARTRefreshResult(result, for: deviceID)
        }
    }

    func performSMARTPrimaryAction() {
        guard let details = state.selectedSMARTDetails else {
            return
        }
        guard details.isRefreshing == false else {
            return
        }

        switch details.primaryAction {
        case .installHelper, .updateHelper:
            state.presentSMARTPrompt(for: details.primaryAction)
        case .refresh:
            refreshSelectedDeviceSMART()
        }
    }

    func dismissSMARTPrompts() {
        state.dismissSMARTPrompts()
    }

    func installSMARTHelper() {
        guard let deviceID = state.presentation.promptDeviceID ?? state.selectedDeviceID,
              let details = state.smartDetails(for: deviceID) else {
            return
        }
        guard details.isRefreshing == false else {
            return
        }
        guard details.primaryAction == .installHelper || details.primaryAction == .updateHelper else {
            return
        }

        state.setSMARTHelperInstalling(for: deviceID)
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            do {
                try await helperInstaller.install()
            } catch {
                state.applySMARTResult(
                    for: deviceID,
                    snapshot: details.snapshot,
                    compatibility: details.compatibility,
                    lastError: error.localizedDescription
                )
                return
            }

            await refreshSelectedDeviceSMARTAfterInstall(for: deviceID)
        }
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
        discoveryWriteGeneration += 1
        let generation = discoveryWriteGeneration
        let deviceDiscovery = deviceDiscovery
        discoveryLoadTask = Task { [weak self] in
            let devices = await deviceDiscovery.discoverDevices()
            guard Task.isCancelled == false else {
                return
            }

            self?.applyDiscoveredDevices(devices, generation: generation)
        }
    }

    private func applyObservedDevices(_ devices: [ExternalDevice]) {
        discoveryWriteGeneration += 1
        state.replaceDevices(devices)
    }

    private func applyDiscoveredDevices(_ devices: [ExternalDevice], generation: Int) {
        guard generation == discoveryWriteGeneration else {
            return
        }

        state.replaceDevices(devices)
    }

    private func refreshSelectedDeviceSMARTAfterInstall(for deviceID: DeviceID) async {
        guard let device = state.device(id: deviceID) else {
            return
        }

        let result = await smartService.refreshSMART(for: device)
        applySMARTRefreshResult(result, for: deviceID)
    }

    private func applySMARTRefreshResult(_ result: SMARTServiceRefreshResult, for deviceID: DeviceID) {
        switch result {
        case let .available(smartData, compatibility):
            state.applySMARTResult(
                for: deviceID,
                snapshot: .available(smartData),
                compatibility: compatibility
            )
        case .unsupported:
            state.applySMARTResult(for: deviceID, snapshot: .unsupported, compatibility: nil)
        case .transportUnsupported:
            state.applySMARTResult(for: deviceID, snapshot: .transportUnsupported, compatibility: nil)
        case .helperNotInstalled:
            state.applySMARTResult(for: deviceID, snapshot: .helperNotInstalled, compatibility: nil)
        case .updateRequired:
            state.applySMARTResult(for: deviceID, snapshot: .updateRequired, compatibility: nil)
        case .permissionRequired:
            state.applySMARTResult(for: deviceID, snapshot: .permissionRequired, compatibility: nil)
        case .deviceUnavailable:
            state.applySMARTResult(for: deviceID, snapshot: .deviceUnavailable, compatibility: nil)
        case let .failed(message):
            state.applySMARTResult(
                for: deviceID,
                snapshot: .failed(message),
                compatibility: nil,
                lastError: message
            )
        }
    }
}
