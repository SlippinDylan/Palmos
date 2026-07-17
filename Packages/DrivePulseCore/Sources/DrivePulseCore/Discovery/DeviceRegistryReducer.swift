public struct DeviceRegistryReducer {
    public init() {}

    public func reduce(
        physicalBSDName: String,
        containerBSDName: String?,
        volumes: [MountedVolume],
        identityEvidence: DeviceIdentityEvidence? = nil
    ) -> ExternalDevice {
        var device = ExternalDevice(
            id: (identityEvidence ?? DeviceIdentityEvidence()).deviceID(for: physicalBSDName),
            displayName: physicalBSDName.uppercased(),
            transportName: "External",
            physicalStoreBSDName: physicalBSDName,
            apfsContainerBSDName: containerBSDName,
            volumes: volumes
        )
        device.smartSnapshot = .notRequested
        return device
    }
}
