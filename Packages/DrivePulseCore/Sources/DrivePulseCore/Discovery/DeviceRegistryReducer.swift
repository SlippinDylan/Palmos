public struct DeviceRegistryReducer {
    public init() {}

    public func reduce(
        physicalBSDName: String,
        containerBSDName: String?,
        volumeBSDNames: [String]
    ) -> ExternalDevice {
        ExternalDevice(
            physicalStoreBSDName: physicalBSDName,
            apfsContainerBSDName: containerBSDName,
            volumes: volumeBSDNames.map { MountedVolume(bsdName: $0) }
        )
    }
}
