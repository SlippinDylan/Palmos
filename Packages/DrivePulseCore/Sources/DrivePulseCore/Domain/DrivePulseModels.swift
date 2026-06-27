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

public struct MountedVolume: Equatable, Sendable {
    public var bsdName: String

    public init(bsdName: String) {
        self.bsdName = bsdName
    }
}

public struct ExternalDevice: Equatable, Sendable {
    public var physicalStoreBSDName: String
    public var apfsContainerBSDName: String?
    public var volumes: [MountedVolume]

    public init(
        physicalStoreBSDName: String,
        apfsContainerBSDName: String?,
        volumes: [MountedVolume]
    ) {
        self.physicalStoreBSDName = physicalStoreBSDName
        self.apfsContainerBSDName = apfsContainerBSDName
        self.volumes = volumes
    }
}
