public struct DeviceRegistryReducer {
    public init() {}

    public func reduce(
        physicalBSDName: String,
        containerBSDName: String?,
        volumes: [MountedVolume]
    ) -> ExternalDevice {
        ExternalDevice(
            physicalStoreBSDName: physicalBSDName,
            apfsContainerBSDName: containerBSDName,
            volumes: volumes
        )
    }
}
