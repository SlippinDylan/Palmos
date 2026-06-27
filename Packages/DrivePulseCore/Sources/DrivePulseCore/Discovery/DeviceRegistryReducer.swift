import Foundation

public struct DeviceRegistryReducer {
    public init() {}

    public func reduce(
        physicalBSDName: String,
        containerBSDName: String?,
        volumeBSDNames: [String]
    ) -> ExternalDevice {
        ExternalDevice(
            id: DeviceID(rawValue: physicalBSDName),
            sessionID: UUID(),
            displayName: physicalBSDName,
            vendorName: nil,
            modelName: nil,
            serialNumber: nil,
            firmwareRevision: nil,
            totalCapacityBytes: nil,
            availableCapacityBytes: nil,
            connectionKind: .unknown,
            mountedState: volumeBSDNames.isEmpty ? .notMounted : .mounted,
            deviceBSDName: physicalBSDName,
            physicalStoreBSDName: physicalBSDName,
            apfsContainerBSDName: containerBSDName,
            volumes: volumeBSDNames.map {
                MountedVolume(
                    id: VolumeID(rawValue: $0),
                    name: $0,
                    mountPoint: nil,
                    fileSystem: nil,
                    bsdName: $0,
                    volumeUUID: nil,
                    totalCapacityBytes: nil,
                    availableCapacityBytes: nil,
                    isWritable: nil,
                    ignoresOwnership: nil
                )
            },
            enclosureInfo: nil,
            sessionMetrics: .empty(historyLimit: 60),
            smartSnapshot: .notRequested
        )
    }
}
