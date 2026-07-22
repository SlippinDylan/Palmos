import Foundation
import os.log

import DrivePulseCore

let discoveryLog = Logger(subsystem: "com.drivepulse.app", category: "DeviceDiscovery")

struct DiskDiscoveryRecord: Equatable {
    let bsdName: String
    let parentBSDName: String?
    let wholeDiskBSDName: String?
    let deviceInternal: Bool?
    let isNetworkVolume: Bool
    let isWholeMedia: Bool
    let isEjectable: Bool
    let isPCITunnelled: Bool
    let registryEntryID: UInt64?
    let mediaUUID: String?
    let volumePath: URL?
    let mediaName: String?
    let deviceModel: String?
    let deviceVendor: String?
    let busName: String?
    let deviceProtocol: String?
    let capacityBytes: Int64?
    let mediaContent: String?
    let ioClassPath: [String]

    init(
        bsdName: String,
        parentBSDName: String?,
        wholeDiskBSDName: String? = nil,
        deviceInternal: Bool?,
        isNetworkVolume: Bool,
        isWholeMedia: Bool,
        isEjectable: Bool = false,
        isPCITunnelled: Bool = false,
        registryEntryID: UInt64? = nil,
        volumePath: URL?,
        mediaUUID: String? = nil,
        mediaName: String?,
        deviceModel: String?,
        deviceVendor: String?,
        busName: String?,
        deviceProtocol: String?,
        capacityBytes: Int64?,
        mediaContent: String?,
        ioClassPath: [String]
    ) {
        self.bsdName = bsdName
        self.parentBSDName = parentBSDName
        self.wholeDiskBSDName = wholeDiskBSDName
        self.deviceInternal = deviceInternal
        self.isNetworkVolume = isNetworkVolume
        self.isWholeMedia = isWholeMedia
        self.isEjectable = isEjectable
        self.isPCITunnelled = isPCITunnelled
        self.registryEntryID = registryEntryID
        self.mediaUUID = mediaUUID
        self.volumePath = volumePath
        self.mediaName = mediaName
        self.deviceModel = deviceModel
        self.deviceVendor = deviceVendor
        self.busName = busName
        self.deviceProtocol = deviceProtocol
        self.capacityBytes = capacityBytes
        self.mediaContent = mediaContent
        self.ioClassPath = ioClassPath
    }

    var descriptor: ExternalDeviceDescriptor {
        let isSynthesizedAPFSContainer = isWholeMedia &&
            (ioClassPath.contains(where: {
                let normalized = $0.lowercased()
                return normalized == "appleapfsmedia" || normalized.contains("apfscontainer")
            }) ||
                (parentBSDName != nil && mediaContent?.lowercased().contains("apfs") == true))
        return ExternalDeviceDescriptor(
            deviceInternal: deviceInternal,
            transportPath: transportPath,
            isNetworkVolume: isNetworkVolume,
            isWholeMedia: isWholeMedia,
            backingEvidence: isSynthesizedAPFSContainer ? .unknown : ExternalDeviceEvidenceMapper.map(
                deviceInternal: deviceInternal,
                busName: busName,
                deviceProtocol: deviceProtocol,
                ioClassPath: ioClassPath,
                isPCITunnelled: isPCITunnelled
            )
        )
    }

    var transportPath: [String] {
        [busName, deviceProtocol].compactMap { $0 } + ioClassPath
    }
}

/// Converts platform-specific discovery fields into the small semantic evidence
/// vocabulary consumed by Core. Product policy never depends on IOKit class names.
struct ExternalDeviceEvidenceMapper: Sendable {
    static func map(
        deviceInternal: Bool?,
        busName: String?,
        deviceProtocol: String?,
        ioClassPath: [String],
        isPCITunnelled: Bool
    ) -> MediaBackingEvidence {
        let path = ([busName, deviceProtocol].compactMap { $0 } + ioClassPath)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

        if path.contains(where: isVirtualEvidence) {
            return .virtual
        }

        let hasThunderbolt = path.contains(where: isThunderboltEvidence)
        let hasPCIe = path.contains(where: isPCIeEvidence)
        if hasPCIe && deviceInternal == false && (hasThunderbolt || isPCITunnelled) {
            return .physical(.tunnelledPCIe)
        }
        if path.contains(where: { $0.contains("usb4") }) {
            return .physical(.usb4)
        }
        if hasThunderbolt {
            return .physical(.thunderbolt)
        }
        if path.contains(where: { $0.contains("usb") }) {
            return .physical(.usb)
        }
        if path.contains(where: matchesSDTransport) {
            return .physical(.sd)
        }

        return .unknown
    }

    private static func isVirtualEvidence(_ value: String) -> Bool {
        value.contains("iohdix") ||
            value.contains("disk image") ||
            value.contains("virtual") ||
            value.contains("sparsebundle")
    }

    private static func isThunderboltEvidence(_ value: String) -> Bool {
        value.contains("thunderbolt") || value.hasPrefix("iothunderbolt")
    }

    private static func isPCIeEvidence(_ value: String) -> Bool {
        value.contains("pcie") || value.contains("pci-express") || value.contains("nvme")
    }

    private static func matchesSDTransport(_ value: String) -> Bool {
        let phrases = [
            "sd card", "sdcard", "sd reader", "sd slot", "sd bus", "sd host", "sdhost",
            "sdxc", "sdhc", "microsd"
        ]
        if phrases.contains(where: value.contains) {
            return true
        }

        if value.hasPrefix("iosdhost") || value.hasPrefix("iosdcard") {
            return true
        }

        let separators = CharacterSet.alphanumerics.inverted
        return value.components(separatedBy: separators).contains("sd")
    }
}
