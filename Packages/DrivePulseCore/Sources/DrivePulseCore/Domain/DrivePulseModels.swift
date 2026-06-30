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

    public static func empty(historyLimit: Int) -> Self {
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

public struct SmartData: Equatable, Sendable {
    public var overallHealth: String?
    public var primaryTemperature: Int?
    public var highestTemperature: Int?
    public var sensorTemperatures: [String: Int]
    public var criticalWarning: Int?
    public var availableSpare: Int?
    public var availableSpareThreshold: Int?
    public var percentageUsed: Int?
    public var dataUnitsRead: Int?
    public var dataUnitsWritten: Int?
    public var hostReadCommands: Int?
    public var hostWriteCommands: Int?
    public var controllerBusyTime: Int?
    public var powerCycles: Int?
    public var powerOnHours: Int?
    public var unsafeShutdowns: Int?
    public var mediaIntegrityErrors: Int?
    public var errorLogEntries: Int?
    public var warningTempTime: Int?
    public var criticalTempTime: Int?
    public var warningTempThreshold: Int?
    public var criticalTempThreshold: Int?

    public init(
        overallHealth: String? = nil,
        primaryTemperature: Int? = nil,
        highestTemperature: Int? = nil,
        sensorTemperatures: [String: Int] = [:],
        criticalWarning: Int? = nil,
        availableSpare: Int? = nil,
        availableSpareThreshold: Int? = nil,
        percentageUsed: Int? = nil,
        dataUnitsRead: Int? = nil,
        dataUnitsWritten: Int? = nil,
        hostReadCommands: Int? = nil,
        hostWriteCommands: Int? = nil,
        controllerBusyTime: Int? = nil,
        powerCycles: Int? = nil,
        powerOnHours: Int? = nil,
        unsafeShutdowns: Int? = nil,
        mediaIntegrityErrors: Int? = nil,
        errorLogEntries: Int? = nil,
        warningTempTime: Int? = nil,
        criticalTempTime: Int? = nil,
        warningTempThreshold: Int? = nil,
        criticalTempThreshold: Int? = nil
    ) {
        self.overallHealth = overallHealth
        self.primaryTemperature = primaryTemperature
        self.highestTemperature = highestTemperature
        self.sensorTemperatures = sensorTemperatures
        self.criticalWarning = criticalWarning
        self.availableSpare = availableSpare
        self.availableSpareThreshold = availableSpareThreshold
        self.percentageUsed = percentageUsed
        self.dataUnitsRead = dataUnitsRead
        self.dataUnitsWritten = dataUnitsWritten
        self.hostReadCommands = hostReadCommands
        self.hostWriteCommands = hostWriteCommands
        self.controllerBusyTime = controllerBusyTime
        self.powerCycles = powerCycles
        self.powerOnHours = powerOnHours
        self.unsafeShutdowns = unsafeShutdowns
        self.mediaIntegrityErrors = mediaIntegrityErrors
        self.errorLogEntries = errorLogEntries
        self.warningTempTime = warningTempTime
        self.criticalTempTime = criticalTempTime
        self.warningTempThreshold = warningTempThreshold
        self.criticalTempThreshold = criticalTempThreshold
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

    public init(bsdName: String) {
        self.bsdName = bsdName
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
        sessionMetrics: DeviceSessionMetrics = .empty(historyLimit: DeviceSessionMetrics.defaultHistoryLimit),
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
            id: DeviceID(rawValue: physicalStoreBSDName),
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
                overallHealth: "Verified",
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
