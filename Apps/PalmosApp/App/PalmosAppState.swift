import Foundation

import PalmosCore

enum SMARTPresentationPrimaryAction: Equatable {
    case installHelper
    case updateHelper
    case refresh
}

enum SMARTSectionPresentationState<Value: Equatable & Sendable>: Equatable {
    case notRequested
    case refreshing(previous: SmartReportSection<Value>?, startedAt: Date)
    case available(SmartReportSection<Value>, sampledAt: Date)
    case failed(previous: SmartReportSection<Value>?, message: String, attemptedAt: Date)
    case unsupported

    var previousValue: SmartReportSection<Value>? {
        switch self {
        case let .refreshing(previous, _), let .failed(previous, _, _):
            return previous
        case let .available(value, _):
            return value
        case .notRequested, .unsupported:
            return nil
        }
    }
}

struct SMARTReportPresentationState: Equatable {
    var health: SMARTSectionPresentationState<SmartHealthReport>
    var thermal: SMARTSectionPresentationState<SmartThermalReport>
    var endurance: SMARTSectionPresentationState<SmartEnduranceReport>
    var lifetime: SMARTSectionPresentationState<SmartLifetimeReport>

    static let notRequested = SMARTReportPresentationState(
        health: .notRequested,
        thermal: .notRequested,
        endurance: .notRequested,
        lifetime: .notRequested
    )

    init(report: SmartReport, sampledAt: Date) {
        health = Self.presentationState(for: report.health, sampledAt: sampledAt)
        thermal = Self.presentationState(for: report.thermal, sampledAt: sampledAt)
        endurance = Self.presentationState(for: report.endurance, sampledAt: sampledAt)
        lifetime = Self.presentationState(for: report.lifetime, sampledAt: sampledAt)
    }

    private init(
        health: SMARTSectionPresentationState<SmartHealthReport>,
        thermal: SMARTSectionPresentationState<SmartThermalReport>,
        endurance: SMARTSectionPresentationState<SmartEnduranceReport>,
        lifetime: SMARTSectionPresentationState<SmartLifetimeReport>
    ) {
        self.health = health
        self.thermal = thermal
        self.endurance = endurance
        self.lifetime = lifetime
    }

    mutating func beginRefreshing(
        sections: Set<SmartReportSectionKind>,
        startedAt: Date
    ) {
        if sections.contains(.health) {
            health = .refreshing(previous: health.previousValue, startedAt: startedAt)
        }
        if sections.contains(.thermal) {
            thermal = .refreshing(previous: thermal.previousValue, startedAt: startedAt)
        }
        if sections.contains(.endurance) {
            endurance = .refreshing(previous: endurance.previousValue, startedAt: startedAt)
        }
        if sections.contains(.lifetime) {
            lifetime = .refreshing(previous: lifetime.previousValue, startedAt: startedAt)
        }
    }

    mutating func apply(
        report: SmartReport,
        sections: Set<SmartReportSectionKind>,
        sampledAt: Date
    ) {
        if sections.contains(.health) {
            health = Self.presentationState(for: report.health, sampledAt: sampledAt)
        }
        if sections.contains(.thermal) {
            thermal = Self.presentationState(for: report.thermal, sampledAt: sampledAt)
        }
        if sections.contains(.endurance) {
            endurance = Self.presentationState(for: report.endurance, sampledAt: sampledAt)
        }
        if sections.contains(.lifetime) {
            lifetime = Self.presentationState(for: report.lifetime, sampledAt: sampledAt)
        }
    }

    mutating func fail(
        sections: Set<SmartReportSectionKind>,
        message: String,
        attemptedAt: Date
    ) {
        if sections.contains(.health) {
            health = .failed(previous: health.previousValue, message: message, attemptedAt: attemptedAt)
        }
        if sections.contains(.thermal) {
            thermal = .failed(previous: thermal.previousValue, message: message, attemptedAt: attemptedAt)
        }
        if sections.contains(.endurance) {
            endurance = .failed(previous: endurance.previousValue, message: message, attemptedAt: attemptedAt)
        }
        if sections.contains(.lifetime) {
            lifetime = .failed(previous: lifetime.previousValue, message: message, attemptedAt: attemptedAt)
        }
    }

    private static func presentationState<Value>(
        for section: SmartReportSection<Value>,
        sampledAt: Date
    ) -> SMARTSectionPresentationState<Value> where Value: Equatable & Sendable {
        switch section {
        case .unsupported:
            return .unsupported
        case .available, .degraded:
            return .available(section, sampledAt: sampledAt)
        }
    }
}

struct SMARTPresentationDetails: Equatable {
    var snapshot: SmartSnapshot
    var reportState: SMARTReportPresentationState
    var compatibility: XPCCompatibilityResult?
    var isRefreshing: Bool
    var isInstalling: Bool
    var lastError: String?

    init(
        snapshot: SmartSnapshot,
        reportState: SMARTReportPresentationState? = nil,
        compatibility: XPCCompatibilityResult?,
        isRefreshing: Bool,
        isInstalling: Bool,
        lastError: String?
    ) {
        self.snapshot = snapshot
        self.reportState = reportState ?? Self.makeReportState(from: snapshot)
        self.compatibility = compatibility
        self.isRefreshing = isRefreshing
        self.isInstalling = isInstalling
        self.lastError = lastError
    }

    var primaryAction: SMARTPresentationPrimaryAction {
        switch snapshot {
        case .helperNotInstalled:
            return .installHelper
        case .companionUnavailable, .updateRequired:
            return .updateHelper
        default:
            return .refresh
        }
    }

    private static func makeReportState(from snapshot: SmartSnapshot) -> SMARTReportPresentationState {
        guard case let .available(data) = snapshot else {
            return .notRequested
        }
        return SMARTReportPresentationState(report: data.report, sampledAt: .distantPast)
    }
}

struct PalmosAppState: Equatable {
    var devices: [ExternalDevice]
    var selectedDeviceID: DeviceID?
    private var smartDetailsByDeviceID: [DeviceID: SMARTPresentationDetails]

    init(devices: [ExternalDevice] = [], selectedDeviceID: DeviceID?) {
        self.devices = devices
        self.selectedDeviceID = Self.resolveSelection(
            devices: devices,
            preferredID: selectedDeviceID
        )
        self.smartDetailsByDeviceID = [:]
    }

    var selectedDevice: ExternalDevice? {
        guard let selectedDeviceID else {
            return devices.first
        }

        return devices.first(where: { $0.id == selectedDeviceID }) ?? devices.first
    }

    /// Returns mounted devices for operations that specifically require a volume.
    /// The picker and selected panel intentionally use `devices`, including
    /// physically present media with no mounted volume.
    var mountedDevices: [ExternalDevice] {
        devices.filter { $0.volumes.isEmpty == false }
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
    }

    mutating func markDeviceUnmounted(_ deviceID: DeviceID) {
        guard let deviceIndex = devices.firstIndex(where: { $0.id == deviceID }) else {
            return
        }

        devices[deviceIndex].volumes.removeAll()
        selectedDeviceID = Self.resolveSelection(
            devices: devices,
            preferredID: selectedDeviceID
        )
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

    mutating func setSMARTRefreshing(
        for deviceID: DeviceID,
        sections: Set<SmartReportSectionKind>,
        startedAt: Date
    ) {
        guard device(id: deviceID) != nil else {
            return
        }
        var details = smartDetails(for: deviceID) ?? SMARTPresentationDetails(
            snapshot: .notRequested,
            compatibility: nil,
            isRefreshing: false,
            isInstalling: false,
            lastError: nil
        )
        details.reportState.beginRefreshing(sections: sections, startedAt: startedAt)
        details.isRefreshing = true
        details.isInstalling = false
        details.lastError = nil
        smartDetailsByDeviceID[deviceID] = details
    }

    mutating func applySMARTReportPatch(
        for deviceID: DeviceID,
        report patch: SmartReport,
        sections: Set<SmartReportSectionKind>,
        compatibility: XPCCompatibilityResult?,
        sampledAt: Date
    ) {
        guard let device = device(id: deviceID) else {
            return
        }
        let existingDetails = smartDetails(for: deviceID)
        let mergedData: SmartData
        if case let .available(existingData) = device.smartSnapshot {
            mergedData = existingData.merging(patch, sections: sections)
        } else if case let .available(existingData) = existingDetails?.snapshot {
            mergedData = existingData.merging(patch, sections: sections)
        } else {
            mergedData = SmartData(report: SmartReport().merging(patch, sections: sections))
        }
        var reportState = existingDetails?.reportState ?? .notRequested
        reportState.apply(report: patch, sections: sections, sampledAt: sampledAt)
        applySMARTDetails(
            for: deviceID,
            snapshot: .available(mergedData),
            reportState: reportState,
            compatibility: compatibility,
            isRefreshing: false,
            lastError: nil
        )
    }

    mutating func failSMARTReportSections(
        for deviceID: DeviceID,
        sections: Set<SmartReportSectionKind>,
        message: String,
        attemptedAt: Date
    ) {
        guard device(id: deviceID) != nil,
              var details = smartDetails(for: deviceID) else {
            return
        }
        details.reportState.fail(sections: sections, message: message, attemptedAt: attemptedAt)
        details.isRefreshing = false
        details.lastError = message
        smartDetailsByDeviceID[deviceID] = details
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

    private mutating func applySMARTDetails(
        for deviceID: DeviceID,
        snapshot: SmartSnapshot,
        reportState: SMARTReportPresentationState,
        compatibility: XPCCompatibilityResult?,
        isRefreshing: Bool,
        lastError: String?
    ) {
        updateDeviceSnapshot(snapshot, for: deviceID)
        smartDetailsByDeviceID[deviceID] = SMARTPresentationDetails(
            snapshot: snapshot,
            reportState: reportState,
            compatibility: compatibility,
            isRefreshing: isRefreshing,
            isInstalling: false,
            lastError: lastError
        )
    }
}
