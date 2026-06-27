import Foundation

public struct SpeedPoint: Equatable, Sendable {
    public let timestamp: Date
    public let bytesPerSecond: Double

    public init(timestamp: Date, bytesPerSecond: Double) {
        self.timestamp = timestamp
        self.bytesPerSecond = bytesPerSecond
    }
}

public struct DeviceSessionMetrics: Equatable, Sendable {
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
        _ = historyLimit
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

    public init(
        overallHealth: String? = nil,
        primaryTemperature: Int? = nil,
        highestTemperature: Int? = nil,
        sensorTemperatures: [String: Int] = [:]
    ) {
        self.overallHealth = overallHealth
        self.primaryTemperature = primaryTemperature
        self.highestTemperature = highestTemperature
        self.sensorTemperatures = sensorTemperatures
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

public struct DeviceID: RawRepresentable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct VolumeID: RawRepresentable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public enum ConnectionKind: Equatable, Sendable {
    case unknown
}

public enum MountedState: Equatable, Sendable {
    case notMounted
    case mounted
}

public struct MountedVolume: Equatable, Sendable {
    public var id: VolumeID
    public var name: String
    public var mountPoint: String?
    public var fileSystem: String?
    public var bsdName: String
    public var volumeUUID: UUID?
    public var totalCapacityBytes: Int64?
    public var availableCapacityBytes: Int64?
    public var isWritable: Bool?
    public var ignoresOwnership: Bool?

    public init(
        id: VolumeID,
        name: String,
        mountPoint: String?,
        fileSystem: String?,
        bsdName: String,
        volumeUUID: UUID?,
        totalCapacityBytes: Int64?,
        availableCapacityBytes: Int64?,
        isWritable: Bool?,
        ignoresOwnership: Bool?
    ) {
        self.id = id
        self.name = name
        self.mountPoint = mountPoint
        self.fileSystem = fileSystem
        self.bsdName = bsdName
        self.volumeUUID = volumeUUID
        self.totalCapacityBytes = totalCapacityBytes
        self.availableCapacityBytes = availableCapacityBytes
        self.isWritable = isWritable
        self.ignoresOwnership = ignoresOwnership
    }
}

public struct ExternalDevice: Equatable, Sendable {
    public var id: DeviceID
    public var sessionID: UUID
    public var displayName: String
    public var vendorName: String?
    public var modelName: String?
    public var serialNumber: String?
    public var firmwareRevision: String?
    public var totalCapacityBytes: Int64?
    public var availableCapacityBytes: Int64?
    public var connectionKind: ConnectionKind
    public var mountedState: MountedState
    public var deviceBSDName: String
    public var physicalStoreBSDName: String
    public var apfsContainerBSDName: String?
    public var volumes: [MountedVolume]
    public var enclosureInfo: String?
    public var sessionMetrics: DeviceSessionMetrics
    public var smartSnapshot: SmartSnapshot

    public init(
        id: DeviceID,
        sessionID: UUID,
        displayName: String,
        vendorName: String?,
        modelName: String?,
        serialNumber: String?,
        firmwareRevision: String?,
        totalCapacityBytes: Int64?,
        availableCapacityBytes: Int64?,
        connectionKind: ConnectionKind,
        mountedState: MountedState,
        deviceBSDName: String,
        physicalStoreBSDName: String,
        apfsContainerBSDName: String?,
        volumes: [MountedVolume],
        enclosureInfo: String?,
        sessionMetrics: DeviceSessionMetrics,
        smartSnapshot: SmartSnapshot
    ) {
        self.id = id
        self.sessionID = sessionID
        self.displayName = displayName
        self.vendorName = vendorName
        self.modelName = modelName
        self.serialNumber = serialNumber
        self.firmwareRevision = firmwareRevision
        self.totalCapacityBytes = totalCapacityBytes
        self.availableCapacityBytes = availableCapacityBytes
        self.connectionKind = connectionKind
        self.mountedState = mountedState
        self.deviceBSDName = deviceBSDName
        self.physicalStoreBSDName = physicalStoreBSDName
        self.apfsContainerBSDName = apfsContainerBSDName
        self.volumes = volumes
        self.enclosureInfo = enclosureInfo
        self.sessionMetrics = sessionMetrics
        self.smartSnapshot = smartSnapshot
    }
}
