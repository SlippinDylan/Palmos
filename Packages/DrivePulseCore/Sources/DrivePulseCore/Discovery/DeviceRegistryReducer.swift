import Foundation

public struct DeviceRegistryReducer {
    public init() {}

    public func reduce(
        physicalBSDName: String,
        containerBSDName: String?,
        volumes: [MountedVolume],
        identityEvidence: DeviceIdentityEvidence? = nil
    ) -> ExternalDevice {
        let resolvedEvidence = identityEvidence ?? DeviceIdentityEvidence(
            sessionID: UUID().uuidString
        )
        var device = ExternalDevice(
            id: resolvedEvidence.deviceID(for: physicalBSDName),
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
