import Foundation

public struct NVMeInfo: Equatable, Sendable {
    public var controller: String?
    public var model: String?
    public var serialNumber: String?
    public var firmwareVersion: String?
    public var nvmeVersion: String?
    public var trimSupport: Bool?
    public var linkWidth: String?
    public var linkSpeed: String?
    public var ieeeOui: String?
    public var firmwareSlots: Int?
    public var firmwareUpdateRequiresReset: Bool?

    public init(
        controller: String? = nil,
        model: String? = nil,
        serialNumber: String? = nil,
        firmwareVersion: String? = nil,
        nvmeVersion: String? = nil,
        trimSupport: Bool? = nil,
        linkWidth: String? = nil,
        linkSpeed: String? = nil,
        ieeeOui: String? = nil,
        firmwareSlots: Int? = nil,
        firmwareUpdateRequiresReset: Bool? = nil
    ) {
        self.controller = controller
        self.model = model
        self.serialNumber = serialNumber
        self.firmwareVersion = firmwareVersion
        self.nvmeVersion = nvmeVersion
        self.trimSupport = trimSupport
        self.linkWidth = linkWidth
        self.linkSpeed = linkSpeed
        self.ieeeOui = ieeeOui
        self.firmwareSlots = firmwareSlots
        self.firmwareUpdateRequiresReset = firmwareUpdateRequiresReset
    }
}

public struct ThunderboltInfo: Equatable, Sendable {
    public var vendorName: String?
    public var deviceName: String?
    public var mode: String?
    public var bus: Int?
    public var receptacle: Int?
    public var linkSpeed: String?
    public var uid: String?
    public var firmwareVersion: String?
    public var linkControllerFirmwareVersion: String?
    public var upstreamPortStatus: String?

    public init(
        vendorName: String? = nil,
        deviceName: String? = nil,
        mode: String? = nil,
        bus: Int? = nil,
        receptacle: Int? = nil,
        linkSpeed: String? = nil,
        uid: String? = nil,
        firmwareVersion: String? = nil,
        linkControllerFirmwareVersion: String? = nil,
        upstreamPortStatus: String? = nil
    ) {
        self.vendorName = vendorName
        self.deviceName = deviceName
        self.mode = mode
        self.bus = bus
        self.receptacle = receptacle
        self.linkSpeed = linkSpeed
        self.uid = uid
        self.firmwareVersion = firmwareVersion
        self.linkControllerFirmwareVersion = linkControllerFirmwareVersion
        self.upstreamPortStatus = upstreamPortStatus
    }
}

public struct PCIInfo: Equatable, Sendable {
    public var slot: String?
    public var vendorID: String?
    public var deviceID: String?
    public var linkStatus: String?
    public var tunnelCompatible: Bool?
    public var linkWidth: String?
    public var linkSpeed: String?

    public init(
        slot: String? = nil,
        vendorID: String? = nil,
        deviceID: String? = nil,
        linkStatus: String? = nil,
        tunnelCompatible: Bool? = nil,
        linkWidth: String? = nil,
        linkSpeed: String? = nil
    ) {
        self.slot = slot
        self.vendorID = vendorID
        self.deviceID = deviceID
        self.linkStatus = linkStatus
        self.tunnelCompatible = tunnelCompatible
        self.linkWidth = linkWidth
        self.linkSpeed = linkSpeed
    }
}

public struct APFSVolumeDetails: Equatable, Sendable {
    public var volumeName: String
    public var bsdName: String
    public var mountPoint: String?
    public var fileSystem: String?
    public var caseSensitive: Bool?
    public var role: String?
    public var capacityConsumedBytes: Int64?
    public var fileVaultEnabled: Bool?
    public var sealed: Bool?
    public var writable: Bool?
    public var ignoreOwnership: Bool?
    public var volumeUUID: String?
    public var logicalBlockSize: Int?
    public var isVolumeDetailComplete: Bool

    public init(
        volumeName: String,
        bsdName: String,
        mountPoint: String? = nil,
        fileSystem: String? = nil,
        caseSensitive: Bool? = nil,
        role: String? = nil,
        capacityConsumedBytes: Int64? = nil,
        fileVaultEnabled: Bool? = nil,
        sealed: Bool? = nil,
        writable: Bool? = nil,
        ignoreOwnership: Bool? = nil,
        volumeUUID: String? = nil,
        logicalBlockSize: Int? = nil,
        isVolumeDetailComplete: Bool = true
    ) {
        self.volumeName = volumeName
        self.bsdName = bsdName
        self.mountPoint = mountPoint
        self.fileSystem = fileSystem
        self.caseSensitive = caseSensitive
        self.role = role
        self.capacityConsumedBytes = capacityConsumedBytes
        self.fileVaultEnabled = fileVaultEnabled
        self.sealed = sealed
        self.writable = writable
        self.ignoreOwnership = ignoreOwnership
        self.volumeUUID = volumeUUID
        self.logicalBlockSize = logicalBlockSize
        self.isVolumeDetailComplete = isVolumeDetailComplete
    }
}

public struct PhysicalPartitionInfo: Equatable, Sendable {
    public var bsdName: String
    public var partitionType: String?
    public var name: String?
    public var sizeBytes: Int64?

    public init(
        bsdName: String,
        partitionType: String? = nil,
        name: String? = nil,
        sizeBytes: Int64? = nil
    ) {
        self.bsdName = bsdName
        self.partitionType = partitionType
        self.name = name
        self.sizeBytes = sizeBytes
    }
}

public struct APFSContainerInfo: Equatable, Sendable {
    public var bsdName: String
    public var physicalStoreBSDName: String?
    public var containerUUID: String?
    public var physicalStoreUUID: String?
    public var totalCapacityBytes: Int64?
    public var capacityInUseBytes: Int64?
    public var capacityNotAllocatedBytes: Int64?
    public var volumes: [APFSVolumeDetails]

    public init(
        bsdName: String,
        physicalStoreBSDName: String? = nil,
        containerUUID: String? = nil,
        physicalStoreUUID: String? = nil,
        totalCapacityBytes: Int64? = nil,
        capacityInUseBytes: Int64? = nil,
        capacityNotAllocatedBytes: Int64? = nil,
        volumes: [APFSVolumeDetails] = []
    ) {
        self.bsdName = bsdName
        self.physicalStoreBSDName = physicalStoreBSDName
        self.containerUUID = containerUUID
        self.physicalStoreUUID = physicalStoreUUID
        self.totalCapacityBytes = totalCapacityBytes
        self.capacityInUseBytes = capacityInUseBytes
        self.capacityNotAllocatedBytes = capacityNotAllocatedBytes
        self.volumes = volumes
    }
}
