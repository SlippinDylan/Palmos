import Foundation

public enum DeviceIdentityResolver {
    public static func isExternalPhysicalDevice(_ descriptor: ExternalDeviceDescriptor) -> Bool {
        guard descriptor.isWholeMedia else { return false }
        guard descriptor.isNetworkVolume == false else { return false }
        guard descriptor.deviceInternal != true else { return false }

        // DA explicitly marks this disk as not-internal: trust it.
        // Thunderbolt-tunneled PCIe NVMe enclosures report Protocol=PCI-Express,
        // so transport-path heuristics alone cannot classify them correctly.
        if descriptor.deviceInternal == false {
            return true
        }

        return descriptor.transportPath.contains(where: isSupportedExternalTransportPath)
    }

    private static func isSupportedExternalTransportPath(_ path: String) -> Bool {
        let normalizedPath = path.lowercased()

        if ["usb", "thunderbolt", "usb4"].contains(where: normalizedPath.contains) {
            return true
        }

        return matchesSDTransport(in: normalizedPath)
    }

    private static func matchesSDTransport(in path: String) -> Bool {
        let sdPhrases = [
            "sd card",
            "sd reader",
            "sd slot",
            "sd bus",
            "sd host",
            "sdxc",
            "sdhc",
            "microsd"
        ]

        if sdPhrases.contains(where: path.contains) {
            return true
        }

        let separators = CharacterSet.alphanumerics.inverted
        let tokens = path.components(separatedBy: separators).filter { $0.isEmpty == false }
        return tokens.contains("sd")
    }
}
