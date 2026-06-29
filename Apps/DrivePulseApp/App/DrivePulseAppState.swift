import Foundation

import DrivePulseCore

enum SMARTPresentationPrimaryAction: Equatable {
    case installHelper
    case updateHelper
    case refresh
}

struct SMARTPresentationDetails: Equatable {
    var snapshot: SmartSnapshot
    var compatibility: XPCCompatibilityResult?
    var isRefreshing: Bool
    var isInstalling: Bool
    var lastError: String?

    var primaryAction: SMARTPresentationPrimaryAction {
        switch snapshot {
        case .helperNotInstalled:
            return .installHelper
        case .updateRequired:
            return .updateHelper
        default:
            return .refresh
        }
    }
}

struct SMARTPromptPresentation: Equatable {
    var showHelperInstallPrompt = false
    var showHelperUpdatePrompt = false
    var promptDeviceID: DeviceID?
}

struct DrivePulseAppState: Equatable {
    var devices: [ExternalDevice]
    var selectedDeviceID: DeviceID?
    var presentation: SMARTPromptPresentation
    private var smartDetailsByDeviceID: [DeviceID: SMARTPresentationDetails]

    init(devices: [ExternalDevice] = [], selectedDeviceID: DeviceID?) {
        self.devices = devices
        self.selectedDeviceID = Self.resolveSelection(
            devices: devices,
            preferredID: selectedDeviceID
        )
        self.presentation = SMARTPromptPresentation()
        self.smartDetailsByDeviceID = [:]
    }

    var selectedDevice: ExternalDevice? {
        guard let selectedDeviceID else {
            return devices.first
        }

        return devices.first(where: { $0.id == selectedDeviceID }) ?? devices.first
    }

    var selectedSMARTDetails: SMARTPresentationDetails? {
        guard let selectedDevice else {
            return nil
        }

        return smartDetails(for: selectedDevice.id)
    }

    mutating func selectDevice(_ id: DeviceID?) {
        selectedDeviceID = Self.resolveSelection(devices: devices, preferredID: id)
    }

    mutating func replaceDevices(_ devices: [ExternalDevice]) {
        let previousSelection = selectedDeviceID
        let existingDevicesByID = Dictionary(uniqueKeysWithValues: self.devices.map { ($0.id, $0) })
        let presentDeviceIDs = Set(devices.map(\.id))
        self.devices = devices
        for index in self.devices.indices {
            let deviceID = self.devices[index].id
            let existingSnapshot = existingDevicesByID[deviceID]?.smartSnapshot
            let existingMetrics = existingDevicesByID[deviceID]?.sessionMetrics
            let storedDetails = smartDetailsByDeviceID[deviceID]
            self.devices[index].smartSnapshot = Self.preservedSnapshot(
                incoming: self.devices[index].smartSnapshot,
                existing: existingSnapshot,
                storedDetails: storedDetails
            )
            if let existingMetrics {
                self.devices[index].sessionMetrics = existingMetrics
            }
        }

        smartDetailsByDeviceID = smartDetailsByDeviceID.filter { presentDeviceIDs.contains($0.key) }
        selectedDeviceID = Self.resolveSelection(
            devices: self.devices,
            preferredID: selectedDeviceID
        )
        if selectedDeviceID != previousSelection {
            dismissSMARTPrompts()
        }
    }

    func smartDetails(for deviceID: DeviceID) -> SMARTPresentationDetails? {
        if let details = smartDetailsByDeviceID[deviceID] {
            return details
        }

        return Self.makeSMARTDetails(for: device(id: deviceID))
    }

    func device(id: DeviceID) -> ExternalDevice? {
        devices.first(where: { $0.id == id })
    }

    mutating func setSMARTRefreshing(for deviceID: DeviceID) {
        guard device(id: deviceID) != nil else {
            return
        }

        let existingDetails = smartDetails(for: deviceID) ?? SMARTPresentationDetails(
            snapshot: .notRequested,
            compatibility: nil,
            isRefreshing: false,
            isInstalling: false,
            lastError: nil
        )
        smartDetailsByDeviceID[deviceID] = SMARTPresentationDetails(
            snapshot: .loading,
            compatibility: existingDetails.compatibility,
            isRefreshing: true,
            isInstalling: false,
            lastError: nil
        )
        updateDeviceSnapshot(.loading, for: deviceID)
    }

    mutating func setSMARTHelperInstalling(for deviceID: DeviceID) {
        guard let details = smartDetails(for: deviceID) else {
            return
        }

        dismissSMARTPrompts()
        smartDetailsByDeviceID[deviceID] = SMARTPresentationDetails(
            snapshot: details.snapshot,
            compatibility: details.compatibility,
            isRefreshing: true,
            isInstalling: true,
            lastError: nil
        )
    }

    mutating func applySMARTResult(
        for deviceID: DeviceID,
        snapshot: SmartSnapshot,
        compatibility: XPCCompatibilityResult?,
        lastError: String? = nil
    ) {
        guard device(id: deviceID) != nil else {
            return
        }

        updateDeviceSnapshot(snapshot, for: deviceID)
        smartDetailsByDeviceID[deviceID] = SMARTPresentationDetails(
            snapshot: snapshot,
            compatibility: compatibility,
            isRefreshing: false,
            isInstalling: false,
            lastError: lastError
        )
    }

    mutating func applySessionMetrics(_ sessionMetrics: DeviceSessionMetrics, for deviceID: DeviceID) {
        guard let deviceIndex = devices.firstIndex(where: { $0.id == deviceID }) else {
            return
        }

        devices[deviceIndex].sessionMetrics = sessionMetrics
    }

    mutating func presentSMARTPrompt(for action: SMARTPresentationPrimaryAction) {
        guard let deviceID = selectedDeviceID else {
            dismissSMARTPrompts()
            return
        }

        presentation.promptDeviceID = deviceID
        switch action {
        case .installHelper:
            presentation.showHelperInstallPrompt = true
            presentation.showHelperUpdatePrompt = false
        case .updateHelper:
            presentation.showHelperInstallPrompt = false
            presentation.showHelperUpdatePrompt = true
        case .refresh:
            dismissSMARTPrompts()
        }
    }

    mutating func dismissSMARTPrompts() {
        presentation.showHelperInstallPrompt = false
        presentation.showHelperUpdatePrompt = false
        presentation.promptDeviceID = nil
    }

    private static func resolveSelection(
        devices: [ExternalDevice],
        preferredID: DeviceID?
    ) -> DeviceID? {
        guard let preferredID else {
            return devices.first?.id
        }

        return devices.contains(where: { $0.id == preferredID })
            ? preferredID
            : devices.first?.id
    }

    private static func makeSMARTDetails(for device: ExternalDevice?) -> SMARTPresentationDetails? {
        guard let device else {
            return nil
        }

        return SMARTPresentationDetails(
            snapshot: device.smartSnapshot,
            compatibility: nil,
            isRefreshing: false,
            isInstalling: false,
            lastError: nil
        )
    }

    private static func preservedSnapshot(
        incoming: SmartSnapshot,
        existing: SmartSnapshot?,
        storedDetails: SMARTPresentationDetails?
    ) -> SmartSnapshot {
        if let storedDetails,
           storedDetails.isRefreshing,
           storedDetails.snapshot == .loading {
            return .loading
        }

        if let storedSnapshot = meaningfulSnapshot(storedDetails?.snapshot) {
            return storedSnapshot
        }

        if let existingSnapshot = meaningfulSnapshot(existing) {
            return existingSnapshot
        }

        return incoming
    }

    private static func meaningfulSnapshot(_ snapshot: SmartSnapshot?) -> SmartSnapshot? {
        guard let snapshot else {
            return nil
        }

        switch snapshot {
        case .notRequested, .loading:
            return nil
        default:
            return snapshot
        }
    }

    private mutating func updateDeviceSnapshot(_ snapshot: SmartSnapshot, for deviceID: DeviceID) {
        guard let deviceIndex = devices.firstIndex(where: { $0.id == deviceID }) else {
            return
        }

        devices[deviceIndex].smartSnapshot = snapshot
    }
}
