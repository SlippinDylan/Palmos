import Foundation

public enum DeviceIdentityResolver {
    public static func isExternalPhysicalDevice(_ descriptor: ExternalDeviceDescriptor) -> Bool {
        guard descriptor.isWholeMedia else { return false }
        guard descriptor.isNetworkVolume == false else { return false }
        guard descriptor.deviceInternal != true else { return false }

        return descriptor.transportPath.contains { path in
            ["USB", "Thunderbolt", "USB4", "SD"].contains(where: path.localizedCaseInsensitiveContains)
        }
    }
}
