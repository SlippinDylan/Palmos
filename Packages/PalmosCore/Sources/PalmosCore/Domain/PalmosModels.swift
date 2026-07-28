import Foundation

public struct DeviceID: RawRepresentable, Hashable, Sendable, Codable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct SpeedPoint: Equatable, Sendable {
    public let timestamp: Date
    public let bytesPerSecond: Double

    public init(timestamp: Date, bytesPerSecond: Double) {
        self.timestamp = timestamp
        self.bytesPerSecond = bytesPerSecond
    }
}

public struct DeviceSessionMetrics: Equatable, Sendable {
    public static let defaultHistoryLimit = 60

    public var currentReadBytesPerSecond: Double
    public var currentWriteBytesPerSecond: Double
    public var cumulativeReadBytes: Int64
    public var cumulativeWriteBytes: Int64
    public var readHistory: [SpeedPoint]
    public var writeHistory: [SpeedPoint]

    public init(
        currentReadBytesPerSecond: Double,
        currentWriteBytesPerSecond: Double,
        cumulativeReadBytes: Int64,
        cumulativeWriteBytes: Int64,
        readHistory: [SpeedPoint],
        writeHistory: [SpeedPoint]
    ) {
        self.currentReadBytesPerSecond = currentReadBytesPerSecond
        self.currentWriteBytesPerSecond = currentWriteBytesPerSecond
        self.cumulativeReadBytes = cumulativeReadBytes
        self.cumulativeWriteBytes = cumulativeWriteBytes
        self.readHistory = readHistory
        self.writeHistory = writeHistory
    }

    public static func empty() -> Self {
        return .init(
            currentReadBytesPerSecond: 0,
            currentWriteBytesPerSecond: 0,
            cumulativeReadBytes: 0,
            cumulativeWriteBytes: 0,
            readHistory: [],
            writeHistory: []
        )
    }
}

public enum SMARTOverallHealth: String, Codable, Equatable, Sendable {
    case passed
    case failed
}

public enum SmartDataField: String, CaseIterable, Codable, Equatable, Sendable {
    case overallHealth
    case primaryTemperature
    case nvmeTemperature
    case nvmeHealthLog
    case sensorTemperatures
    case criticalWarning
    case availableSpare
    case availableSpareThreshold
    case percentageUsed
    case dataUnitsRead
    case dataUnitsWritten
    case hostReadCommands
    case hostWriteCommands
    case controllerBusyTime
    case powerCycles
    case powerOnHours
    case unsafeShutdowns
    case mediaIntegrityErrors
    case errorLogEntries
    case warningTempTime
    case criticalTempTime
    case warningTempThreshold
    case criticalTempThreshold
}

public enum SmartDataParseIssueReason: Equatable, Sendable {
    case typeMismatch
    case invalidNumericString
    case outOfRange
}

public struct SmartDataParseIssue: Equatable, Sendable {
    public let field: SmartDataField
    public let reason: SmartDataParseIssueReason

    public init(field: SmartDataField, reason: SmartDataParseIssueReason) {
        self.field = field
        self.reason = reason
    }
}

public enum SmartDataParsingQuality: Equatable, Sendable {
    case clean
    case degraded([SmartDataParseIssue])
}

public enum SmartReportSection<Value: Equatable & Sendable>: Equatable, Sendable {
    case unsupported
    case available(Value)
    case degraded(Value, issues: [SmartDataParseIssue])

    public var value: Value? {
        switch self {
        case .unsupported:
            return nil
        case let .available(value), let .degraded(value, _):
            return value
        }
    }

    public var issues: [SmartDataParseIssue] {
        guard case let .degraded(_, issues) = self else {
            return []
        }
        return issues
    }

    fileprivate mutating func update(
        defaultValue: @autoclosure () -> Value,
        _ transform: (inout Value) -> Void
    ) {
        switch self {
        case .unsupported:
            var value = defaultValue()
            transform(&value)
            self = .available(value)
        case let .available(existing):
            var value = existing
            transform(&value)
            self = .available(value)
        case let .degraded(existing, issues):
            var value = existing
            transform(&value)
            self = .degraded(value, issues: issues)
        }
    }
}

public enum SmartReportSectionKind: String, CaseIterable, Equatable, Hashable, Sendable {
    case health
    case thermal
    case endurance
    case lifetime
    case capabilityMetadata
    case errorHistory
    case selfTestHistory
}

public struct SmartHealthReport: Equatable, Sendable {
    public var overallHealth: SMARTOverallHealth?
    public var criticalWarning: Int?
    public var mediaIntegrityErrors: UInt64?
    public var errorLogEntries: UInt64?

    public init(
        overallHealth: SMARTOverallHealth? = nil,
        criticalWarning: Int? = nil,
        mediaIntegrityErrors: UInt64? = nil,
        errorLogEntries: UInt64? = nil
    ) {
        self.overallHealth = overallHealth
        self.criticalWarning = criticalWarning
        self.mediaIntegrityErrors = mediaIntegrityErrors
        self.errorLogEntries = errorLogEntries
    }
}

public struct SmartThermalReport: Equatable, Sendable {
    public var primaryTemperature: Int?
    public var highestTemperature: Int?
    public var sensorTemperatures: [String: Int]
    public var warningTempTime: UInt64?
    public var criticalTempTime: UInt64?
    public var warningTempThreshold: Int?
    public var criticalTempThreshold: Int?

    public init(
        primaryTemperature: Int? = nil,
        highestTemperature: Int? = nil,
        sensorTemperatures: [String: Int] = [:],
        warningTempTime: UInt64? = nil,
        criticalTempTime: UInt64? = nil,
        warningTempThreshold: Int? = nil,
        criticalTempThreshold: Int? = nil
    ) {
        self.primaryTemperature = primaryTemperature
        self.highestTemperature = highestTemperature
        self.sensorTemperatures = sensorTemperatures
        self.warningTempTime = warningTempTime
        self.criticalTempTime = criticalTempTime
        self.warningTempThreshold = warningTempThreshold
        self.criticalTempThreshold = criticalTempThreshold
    }
}

public struct SmartEnduranceReport: Equatable, Sendable {
    public var availableSpare: Int?
    public var availableSpareThreshold: Int?
    public var percentageUsed: Int?

    public init(
        availableSpare: Int? = nil,
        availableSpareThreshold: Int? = nil,
        percentageUsed: Int? = nil
    ) {
        self.availableSpare = availableSpare
        self.availableSpareThreshold = availableSpareThreshold
        self.percentageUsed = percentageUsed
    }
}

public struct SmartLifetimeReport: Equatable, Sendable {
    public var dataUnitsRead: UInt64?
    public var dataUnitsWritten: UInt64?
    public var hostReadCommands: UInt64?
    public var hostWriteCommands: UInt64?
    public var controllerBusyTime: UInt64?
    public var powerCycles: UInt64?
    public var powerOnHours: UInt64?
    public var unsafeShutdowns: UInt64?

    public init(
        dataUnitsRead: UInt64? = nil,
        dataUnitsWritten: UInt64? = nil,
        hostReadCommands: UInt64? = nil,
        hostWriteCommands: UInt64? = nil,
        controllerBusyTime: UInt64? = nil,
        powerCycles: UInt64? = nil,
        powerOnHours: UInt64? = nil,
        unsafeShutdowns: UInt64? = nil
    ) {
        self.dataUnitsRead = dataUnitsRead
        self.dataUnitsWritten = dataUnitsWritten
        self.hostReadCommands = hostReadCommands
        self.hostWriteCommands = hostWriteCommands
        self.controllerBusyTime = controllerBusyTime
        self.powerCycles = powerCycles
        self.powerOnHours = powerOnHours
        self.unsafeShutdowns = unsafeShutdowns
    }
}

public struct SmartCapabilityReport: Equatable, Sendable {
    public var modelFamily: String?
    public var modelName: String?
    public var serialNumber: String?
    public var firmwareVersion: String?
    public var smartAvailable: Bool?
    public var smartEnabled: Bool?
    /// Canonical JSON for capability fields not yet promoted to stable domain properties.
    public var detailsJSON: Data?

    public init(
        modelFamily: String? = nil,
        modelName: String? = nil,
        serialNumber: String? = nil,
        firmwareVersion: String? = nil,
        smartAvailable: Bool? = nil,
        smartEnabled: Bool? = nil,
        detailsJSON: Data? = nil
    ) {
        self.modelFamily = modelFamily
        self.modelName = modelName
        self.serialNumber = serialNumber
        self.firmwareVersion = firmwareVersion
        self.smartAvailable = smartAvailable
        self.smartEnabled = smartEnabled
        self.detailsJSON = detailsJSON
    }
}

public struct SmartErrorHistoryReport: Equatable, Sendable {
    public var loggedErrorCount: UInt64?
    /// Canonical JSON preserves protocol-specific error records without flattening them.
    public var detailsJSON: Data?

    public init(loggedErrorCount: UInt64? = nil, detailsJSON: Data? = nil) {
        self.loggedErrorCount = loggedErrorCount
        self.detailsJSON = detailsJSON
    }
}

public struct SmartSelfTestHistoryReport: Equatable, Sendable {
    public var recordedTestCount: Int?
    public var latestStatus: String?
    /// Canonical JSON preserves ATA, NVMe, and SCSI self-test records.
    public var detailsJSON: Data?

    public init(
        recordedTestCount: Int? = nil,
        latestStatus: String? = nil,
        detailsJSON: Data? = nil
    ) {
        self.recordedTestCount = recordedTestCount
        self.latestStatus = latestStatus
        self.detailsJSON = detailsJSON
    }
}

public struct SmartReport: Equatable, Sendable {
    public var health: SmartReportSection<SmartHealthReport>
    public var thermal: SmartReportSection<SmartThermalReport>
    public var endurance: SmartReportSection<SmartEnduranceReport>
    public var lifetime: SmartReportSection<SmartLifetimeReport>
    public var capabilityMetadata: SmartReportSection<SmartCapabilityReport>
    public var errorHistory: SmartReportSection<SmartErrorHistoryReport>
    public var selfTestHistory: SmartReportSection<SmartSelfTestHistoryReport>

    public init(
        health: SmartReportSection<SmartHealthReport> = .unsupported,
        thermal: SmartReportSection<SmartThermalReport> = .unsupported,
        endurance: SmartReportSection<SmartEnduranceReport> = .unsupported,
        lifetime: SmartReportSection<SmartLifetimeReport> = .unsupported,
        capabilityMetadata: SmartReportSection<SmartCapabilityReport> = .unsupported,
        errorHistory: SmartReportSection<SmartErrorHistoryReport> = .unsupported,
        selfTestHistory: SmartReportSection<SmartSelfTestHistoryReport> = .unsupported
    ) {
        self.health = health
        self.thermal = thermal
        self.endurance = endurance
        self.lifetime = lifetime
        self.capabilityMetadata = capabilityMetadata
        self.errorHistory = errorHistory
        self.selfTestHistory = selfTestHistory
    }

    public var parsingQuality: SmartDataParsingQuality {
        var issues: [SmartDataParseIssue] = []
        for issue in health.issues + thermal.issues + endurance.issues + lifetime.issues +
            capabilityMetadata.issues + errorHistory.issues + selfTestHistory.issues
        where issues.contains(issue) == false {
            issues.append(issue)
        }
        issues.sort { $0.field.rawValue < $1.field.rawValue }
        return issues.isEmpty ? .clean : .degraded(issues)
    }

    public func merging(
        _ patch: SmartReport,
        sections: Set<SmartReportSectionKind>
    ) -> SmartReport {
        SmartReport(
            health: sections.contains(.health) ? patch.health : health,
            thermal: sections.contains(.thermal) ? patch.thermal : thermal,
            endurance: sections.contains(.endurance) ? patch.endurance : endurance,
            lifetime: sections.contains(.lifetime) ? patch.lifetime : lifetime,
            capabilityMetadata: sections.contains(.capabilityMetadata)
                ? patch.capabilityMetadata : capabilityMetadata,
            errorHistory: sections.contains(.errorHistory) ? patch.errorHistory : errorHistory,
            selfTestHistory: sections.contains(.selfTestHistory) ? patch.selfTestHistory : selfTestHistory
        )
    }
}

/// Compatibility facade for existing presentation code. New SMART refresh code
/// should merge the typed sections in `report`, not replace this value wholesale.
public struct SmartData: Equatable, Sendable {
    public var report: SmartReport

    public var overallHealth: SMARTOverallHealth? {
        get { report.health.value?.overallHealth }
        set { report.health.update(defaultValue: .init()) { $0.overallHealth = newValue } }
    }
    public var parsingQuality: SmartDataParsingQuality {
        get { report.parsingQuality }
        set {
            report = SmartData(
                overallHealth: overallHealth,
                parsingQuality: newValue,
                primaryTemperature: primaryTemperature,
                highestTemperature: highestTemperature,
                sensorTemperatures: sensorTemperatures,
                criticalWarning: criticalWarning,
                availableSpare: availableSpare,
                availableSpareThreshold: availableSpareThreshold,
                percentageUsed: percentageUsed,
                dataUnitsRead: dataUnitsRead,
                dataUnitsWritten: dataUnitsWritten,
                hostReadCommands: hostReadCommands,
                hostWriteCommands: hostWriteCommands,
                controllerBusyTime: controllerBusyTime,
                powerCycles: powerCycles,
                powerOnHours: powerOnHours,
                unsafeShutdowns: unsafeShutdowns,
                mediaIntegrityErrors: mediaIntegrityErrors,
                errorLogEntries: errorLogEntries,
                warningTempTime: warningTempTime,
                criticalTempTime: criticalTempTime,
                warningTempThreshold: warningTempThreshold,
                criticalTempThreshold: criticalTempThreshold
            ).report
        }
    }
    public var primaryTemperature: Int? {
        get { report.thermal.value?.primaryTemperature }
        set { report.thermal.update(defaultValue: .init()) { $0.primaryTemperature = newValue } }
    }
    public var highestTemperature: Int? {
        get { report.thermal.value?.highestTemperature }
        set { report.thermal.update(defaultValue: .init()) { $0.highestTemperature = newValue } }
    }
    public var sensorTemperatures: [String: Int] {
        get { report.thermal.value?.sensorTemperatures ?? [:] }
        set { report.thermal.update(defaultValue: .init()) { $0.sensorTemperatures = newValue } }
    }
    public var criticalWarning: Int? {
        get { report.health.value?.criticalWarning }
        set { report.health.update(defaultValue: .init()) { $0.criticalWarning = newValue } }
    }
    public var availableSpare: Int? {
        get { report.endurance.value?.availableSpare }
        set { report.endurance.update(defaultValue: .init()) { $0.availableSpare = newValue } }
    }
    public var availableSpareThreshold: Int? {
        get { report.endurance.value?.availableSpareThreshold }
        set { report.endurance.update(defaultValue: .init()) { $0.availableSpareThreshold = newValue } }
    }
    public var percentageUsed: Int? {
        get { report.endurance.value?.percentageUsed }
        set { report.endurance.update(defaultValue: .init()) { $0.percentageUsed = newValue } }
    }
    public var dataUnitsRead: UInt64? {
        get { report.lifetime.value?.dataUnitsRead }
        set { report.lifetime.update(defaultValue: .init()) { $0.dataUnitsRead = newValue } }
    }
    public var dataUnitsWritten: UInt64? {
        get { report.lifetime.value?.dataUnitsWritten }
        set { report.lifetime.update(defaultValue: .init()) { $0.dataUnitsWritten = newValue } }
    }
    public var hostReadCommands: UInt64? {
        get { report.lifetime.value?.hostReadCommands }
        set { report.lifetime.update(defaultValue: .init()) { $0.hostReadCommands = newValue } }
    }
    public var hostWriteCommands: UInt64? {
        get { report.lifetime.value?.hostWriteCommands }
        set { report.lifetime.update(defaultValue: .init()) { $0.hostWriteCommands = newValue } }
    }
    public var controllerBusyTime: UInt64? {
        get { report.lifetime.value?.controllerBusyTime }
        set { report.lifetime.update(defaultValue: .init()) { $0.controllerBusyTime = newValue } }
    }
    public var powerCycles: UInt64? {
        get { report.lifetime.value?.powerCycles }
        set { report.lifetime.update(defaultValue: .init()) { $0.powerCycles = newValue } }
    }
    public var powerOnHours: UInt64? {
        get { report.lifetime.value?.powerOnHours }
        set { report.lifetime.update(defaultValue: .init()) { $0.powerOnHours = newValue } }
    }
    public var unsafeShutdowns: UInt64? {
        get { report.lifetime.value?.unsafeShutdowns }
        set { report.lifetime.update(defaultValue: .init()) { $0.unsafeShutdowns = newValue } }
    }
    public var mediaIntegrityErrors: UInt64? {
        get { report.health.value?.mediaIntegrityErrors }
        set { report.health.update(defaultValue: .init()) { $0.mediaIntegrityErrors = newValue } }
    }
    public var errorLogEntries: UInt64? {
        get { report.health.value?.errorLogEntries }
        set { report.health.update(defaultValue: .init()) { $0.errorLogEntries = newValue } }
    }
    public var warningTempTime: UInt64? {
        get { report.thermal.value?.warningTempTime }
        set { report.thermal.update(defaultValue: .init()) { $0.warningTempTime = newValue } }
    }
    public var criticalTempTime: UInt64? {
        get { report.thermal.value?.criticalTempTime }
        set { report.thermal.update(defaultValue: .init()) { $0.criticalTempTime = newValue } }
    }
    public var warningTempThreshold: Int? {
        get { report.thermal.value?.warningTempThreshold }
        set { report.thermal.update(defaultValue: .init()) { $0.warningTempThreshold = newValue } }
    }
    public var criticalTempThreshold: Int? {
        get { report.thermal.value?.criticalTempThreshold }
        set { report.thermal.update(defaultValue: .init()) { $0.criticalTempThreshold = newValue } }
    }

    public init(report: SmartReport) {
        self.report = report
    }

    public func merging(
        _ patch: SmartReport,
        sections: Set<SmartReportSectionKind>
    ) -> SmartData {
        SmartData(report: report.merging(patch, sections: sections))
    }

    public init(
        overallHealth: SMARTOverallHealth? = nil,
        parsingQuality: SmartDataParsingQuality = .clean,
        primaryTemperature: Int? = nil,
        highestTemperature: Int? = nil,
        sensorTemperatures: [String: Int] = [:],
        criticalWarning: Int? = nil,
        availableSpare: Int? = nil,
        availableSpareThreshold: Int? = nil,
        percentageUsed: Int? = nil,
        dataUnitsRead: UInt64? = nil,
        dataUnitsWritten: UInt64? = nil,
        hostReadCommands: UInt64? = nil,
        hostWriteCommands: UInt64? = nil,
        controllerBusyTime: UInt64? = nil,
        powerCycles: UInt64? = nil,
        powerOnHours: UInt64? = nil,
        unsafeShutdowns: UInt64? = nil,
        mediaIntegrityErrors: UInt64? = nil,
        errorLogEntries: UInt64? = nil,
        warningTempTime: UInt64? = nil,
        criticalTempTime: UInt64? = nil,
        warningTempThreshold: Int? = nil,
        criticalTempThreshold: Int? = nil
    ) {
        let issues: [SmartDataParseIssue]
        switch parsingQuality {
        case .clean:
            issues = []
        case let .degraded(parseIssues):
            issues = parseIssues
        }
        func section<Value: Equatable & Sendable>(
            _ value: Value,
            fields: Set<SmartDataField>,
            isSupported: Bool
        ) -> SmartReportSection<Value> {
            let sectionIssues = issues.filter { fields.contains($0.field) }
            if sectionIssues.isEmpty == false {
                return .degraded(value, issues: sectionIssues)
            }
            return isSupported ? .available(value) : .unsupported
        }

        let health = SmartHealthReport(
            overallHealth: overallHealth,
            criticalWarning: criticalWarning,
            mediaIntegrityErrors: mediaIntegrityErrors,
            errorLogEntries: errorLogEntries
        )
        let thermal = SmartThermalReport(
            primaryTemperature: primaryTemperature,
            highestTemperature: highestTemperature,
            sensorTemperatures: sensorTemperatures,
            warningTempTime: warningTempTime,
            criticalTempTime: criticalTempTime,
            warningTempThreshold: warningTempThreshold,
            criticalTempThreshold: criticalTempThreshold
        )
        let endurance = SmartEnduranceReport(
            availableSpare: availableSpare,
            availableSpareThreshold: availableSpareThreshold,
            percentageUsed: percentageUsed
        )
        let lifetime = SmartLifetimeReport(
            dataUnitsRead: dataUnitsRead,
            dataUnitsWritten: dataUnitsWritten,
            hostReadCommands: hostReadCommands,
            hostWriteCommands: hostWriteCommands,
            controllerBusyTime: controllerBusyTime,
            powerCycles: powerCycles,
            powerOnHours: powerOnHours,
            unsafeShutdowns: unsafeShutdowns
        )
        report = SmartReport(
            health: section(
                health,
                fields: [
                    .overallHealth, .nvmeHealthLog, .criticalWarning,
                    .mediaIntegrityErrors, .errorLogEntries
                ],
                isSupported: overallHealth != nil || criticalWarning != nil ||
                    mediaIntegrityErrors != nil || errorLogEntries != nil
            ),
            thermal: section(
                thermal,
                fields: [
                    .primaryTemperature, .nvmeHealthLog, .nvmeTemperature, .sensorTemperatures,
                    .warningTempTime, .criticalTempTime, .warningTempThreshold,
                    .criticalTempThreshold
                ],
                isSupported: primaryTemperature != nil || highestTemperature != nil ||
                    sensorTemperatures.isEmpty == false || warningTempTime != nil ||
                    criticalTempTime != nil || warningTempThreshold != nil || criticalTempThreshold != nil
            ),
            endurance: section(
                endurance,
                fields: [
                    .nvmeHealthLog, .availableSpare, .availableSpareThreshold, .percentageUsed
                ],
                isSupported: availableSpare != nil || availableSpareThreshold != nil || percentageUsed != nil
            ),
            lifetime: section(
                lifetime,
                fields: [
                    .nvmeHealthLog, .dataUnitsRead, .dataUnitsWritten, .hostReadCommands,
                    .hostWriteCommands, .controllerBusyTime, .powerCycles,
                    .powerOnHours, .unsafeShutdowns
                ],
                isSupported: dataUnitsRead != nil || dataUnitsWritten != nil ||
                    hostReadCommands != nil || hostWriteCommands != nil ||
                    controllerBusyTime != nil || powerCycles != nil ||
                    powerOnHours != nil || unsafeShutdowns != nil
            ),
            capabilityMetadata: .unsupported,
            errorHistory: .unsupported,
            selfTestHistory: .unsupported
        )
    }
}

public enum XPCCompatibilityResult: Equatable, Sendable {
    case compatible
    case degraded
    case updateRequired
}

public enum XPCCompatibilityPolicy {
    public static func evaluate(
        appMajor: Int,
        appMinor: Int,
        helperMajor: Int,
        helperMinor: Int
    ) -> XPCCompatibilityResult {
        guard appMajor == helperMajor else {
            return .updateRequired
        }

        if helperMinor < appMinor {
            return .degraded
        }

        return .compatible
    }
}

public struct MountedVolume: Equatable, Sendable {
    public var bsdName: String
    public var mountPoint: String?
    public var capacityTotalBytes: Int64?
    public var capacityAvailableBytes: Int64?
    public var capacityConsumedBytes: Int64?

    public init(
        bsdName: String,
        mountPoint: String? = nil,
        capacityTotalBytes: Int64? = nil,
        capacityAvailableBytes: Int64? = nil,
        capacityConsumedBytes: Int64? = nil
    ) {
        self.bsdName = bsdName
        self.mountPoint = mountPoint
        self.capacityTotalBytes = capacityTotalBytes
        self.capacityAvailableBytes = capacityAvailableBytes
        self.capacityConsumedBytes = capacityConsumedBytes
    }
}

extension MountedVolume: Identifiable {
    public var id: String { bsdName }
}

public struct ExternalDevice: Equatable, Sendable, Identifiable {
    public var id: DeviceID
    public var displayName: String
    public var transportName: String
    public var capacityBytes: Int64?
    public var smartSnapshot: SmartSnapshot
    public var sessionMetrics: DeviceSessionMetrics
    public var physicalStoreBSDName: String
    public var apfsContainerBSDName: String?
    public var volumes: [MountedVolume]
    public var nvmeInfo: NVMeInfo?
    public var thunderboltInfo: ThunderboltInfo?
    public var pciInfo: PCIInfo?
    public var apfsContainerDetails: APFSContainerInfo?
    public var physicalPartitions: [PhysicalPartitionInfo]

    public init(
        id: DeviceID,
        displayName: String,
        transportName: String,
        capacityBytes: Int64? = nil,
        smartSnapshot: SmartSnapshot = .notRequested,
        sessionMetrics: DeviceSessionMetrics = .empty(),
        physicalStoreBSDName: String,
        apfsContainerBSDName: String?,
        volumes: [MountedVolume],
        nvmeInfo: NVMeInfo? = nil,
        thunderboltInfo: ThunderboltInfo? = nil,
        pciInfo: PCIInfo? = nil,
        apfsContainerDetails: APFSContainerInfo? = nil,
        physicalPartitions: [PhysicalPartitionInfo] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.transportName = transportName
        self.capacityBytes = capacityBytes
        self.smartSnapshot = smartSnapshot
        self.sessionMetrics = sessionMetrics
        self.physicalStoreBSDName = physicalStoreBSDName
        self.apfsContainerBSDName = apfsContainerBSDName
        self.volumes = volumes
        self.nvmeInfo = nvmeInfo
        self.thunderboltInfo = thunderboltInfo
        self.pciInfo = pciInfo
        self.apfsContainerDetails = apfsContainerDetails
        self.physicalPartitions = physicalPartitions
    }

    public init(
        physicalStoreBSDName: String,
        apfsContainerBSDName: String?,
        volumes: [MountedVolume]
    ) {
        self.init(
            id: DeviceIdentityEvidence(
                sessionID: UUID().uuidString
            ).deviceID(for: physicalStoreBSDName),
            displayName: physicalStoreBSDName.uppercased(),
            transportName: "External",
            physicalStoreBSDName: physicalStoreBSDName,
            apfsContainerBSDName: apfsContainerBSDName,
            volumes: volumes
        )
    }

    public static func preview(id rawID: String) -> Self {
        let identifier = DeviceID(rawValue: rawID)
        let deviceNumber = rawID.filter(\.isNumber)
        let transportName = rawID == "disk8" ? "Thunderbolt" : "USB-C"
        let temperature = rawID == "disk8" ? 31 : 36
        let sessionMetrics = DeviceSessionMetrics(
            currentReadBytesPerSecond: rawID == "disk8" ? 515_000_000 : 242_000_000,
            currentWriteBytesPerSecond: rawID == "disk8" ? 188_000_000 : 121_000_000,
            cumulativeReadBytes: rawID == "disk8" ? 982_000_000_000 : 421_000_000_000,
            cumulativeWriteBytes: rawID == "disk8" ? 411_000_000_000 : 208_000_000_000,
            readHistory: [
                SpeedPoint(timestamp: .now.addingTimeInterval(-60), bytesPerSecond: 180_000_000),
                SpeedPoint(timestamp: .now.addingTimeInterval(-30), bytesPerSecond: 255_000_000),
                SpeedPoint(timestamp: .now, bytesPerSecond: rawID == "disk8" ? 515_000_000 : 242_000_000)
            ],
            writeHistory: [
                SpeedPoint(timestamp: .now.addingTimeInterval(-60), bytesPerSecond: 74_000_000),
                SpeedPoint(timestamp: .now.addingTimeInterval(-30), bytesPerSecond: 96_000_000),
                SpeedPoint(timestamp: .now, bytesPerSecond: rawID == "disk8" ? 188_000_000 : 121_000_000)
            ]
        )

        return .init(
            id: identifier,
            displayName: "External SSD \(deviceNumber)",
            transportName: transportName,
            capacityBytes: rawID == "disk8" ? 2_000_000_000_000 : 1_000_000_000_000,
            smartSnapshot: .available(SmartData(
                overallHealth: .passed,
                primaryTemperature: temperature,
                highestTemperature: temperature + 2,
                sensorTemperatures: ["Composite": temperature]
            )),
            sessionMetrics: sessionMetrics,
            physicalStoreBSDName: rawID,
            apfsContainerBSDName: "\(rawID)s2",
            volumes: [
                MountedVolume(bsdName: "\(rawID)s2"),
                MountedVolume(bsdName: "\(rawID)s3")
            ],
            nvmeInfo: rawID == "disk8" ? nil : NVMeInfo(
                controller: "Apple SSD Controller",
                firmwareVersion: "1221.60.1",
                nvmeVersion: "1.4",
                trimSupport: true,
                linkWidth: "x4",
                linkSpeed: "8.0 GT/s"
            ),
            thunderboltInfo: rawID == "disk8" ? ThunderboltInfo(
                vendorName: "Samsung",
                deviceName: "T9 Portable SSD",
                mode: "Thunderbolt 4",
                linkSpeed: "40 Gbit/s"
            ) : nil
        )
    }
}
