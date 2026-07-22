import DiskArbitration
import Foundation
import IOKit
import IOKit.storage

struct DiskDiscoveryEnumerator {
    private let session: DASession

    init(session: DASession) {
        self.session = session
    }

    func records() -> [DiskDiscoveryRecord] {
        guard let matching = IOServiceMatching(kIOMediaClass) else {
            return []
        }

        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard result == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var discoveredRecords: [DiskDiscoveryRecord] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }

            guard let record = makeRecord(for: service) else {
                continue
            }

            discoveryLog.debug(
                "IOMedia: \(record.bsdName) protocol=\(record.deviceProtocol ?? "-") bus=\(record.busName ?? "-") internal=\(record.deviceInternal.map(String.init) ?? "nil") whole=\(record.isWholeMedia) pciTunnel=\(record.isPCITunnelled) ioPath=[\(record.ioClassPath.prefix(5).joined(separator: "→"))]"
            )
            discoveredRecords.append(record)
        }

        return discoveredRecords
    }

    private func makeRecord(for service: io_service_t) -> DiskDiscoveryRecord? {
        // DADiskCreateFromIOMedia may return nil for synthesized disks such as APFS
        // containers (disk5). Fall back to BSD-name-based creation so those entries
        // remain in recordsByBSD and can serve as chain links during volume mapping.
        let disk: DADisk? = DADiskCreateFromIOMedia(kCFAllocatorDefault, session, service)
            ?? stringProperty(named: "BSD Name", for: service).flatMap { bsdName in
                bsdName.withCString { DADiskCreateFromBSDName(kCFAllocatorDefault, session, $0) }
            }

        guard let disk,
              let bsdNamePointer = DADiskGetBSDName(disk) else {
            return nil
        }

        let bsdName = String(cString: bsdNamePointer)
        let description = DADiskCopyDescription(disk) as? [String: Any]
        let wholeDisk = DADiskCopyWholeDisk(disk)
        let wholeDiskBSDName: String?
        if let wholeDisk,
           let wholeDiskBSDNamePointer = DADiskGetBSDName(wholeDisk) {
            wholeDiskBSDName = String(cString: wholeDiskBSDNamePointer)
        } else {
            wholeDiskBSDName = nil
        }

        let registryEvidence = ioRegistryEvidence(for: service)

        return DiskDiscoveryRecord(
            bsdName: bsdName,
            parentBSDName: parentBSDName(for: service),
            wholeDiskBSDName: wholeDiskBSDName,
            deviceInternal: description?[kDADiskDescriptionDeviceInternalKey as String] as? Bool,
            isNetworkVolume: description?[kDADiskDescriptionVolumeNetworkKey as String] as? Bool ?? false,
            isWholeMedia: description?[kDADiskDescriptionMediaWholeKey as String] as? Bool
                ?? boolProperty(named: kIOMediaWholeKey, for: service)
                ?? false,
            isEjectable: description?[kDADiskDescriptionMediaEjectableKey as String] as? Bool
                ?? boolProperty(named: kIOMediaEjectableKey, for: service)
                ?? false,
            isPCITunnelled: registryEvidence.isPCITunnelled,
            registryEntryID: registryEntryID(for: service),
            volumePath: description?[kDADiskDescriptionVolumePathKey as String] as? URL,
            mediaUUID: mediaUUID(from: description?[kDADiskDescriptionMediaUUIDKey as String]),
            mediaName: description?[kDADiskDescriptionMediaNameKey as String] as? String,
            deviceModel: description?[kDADiskDescriptionDeviceModelKey as String] as? String,
            deviceVendor: description?[kDADiskDescriptionDeviceVendorKey as String] as? String,
            busName: description?[kDADiskDescriptionBusNameKey as String] as? String,
            deviceProtocol: description?[kDADiskDescriptionDeviceProtocolKey as String] as? String,
            capacityBytes: description?[kDADiskDescriptionMediaSizeKey as String] as? Int64
                ?? (description?[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.int64Value
                ?? int64Property(named: kIOMediaSizeKey, for: service),
            mediaContent: description?[kDADiskDescriptionMediaContentKey as String] as? String,
            ioClassPath: registryEvidence.classPath
        )
    }

    private func mediaUUID(from value: Any?) -> String? {
        if let uuid = value as? UUID {
            return uuid.uuidString
        }
        if let uuid = value as? NSUUID {
            return uuid.uuidString
        }
        return nil
    }

    private func parentBSDName(for service: io_service_t) -> String? {
        var current = service
        var ownsCurrent = false

        while true {
            var parent: io_registry_entry_t = 0
            let result = IORegistryEntryGetParentEntry(current, "IOService", &parent)

            if ownsCurrent {
                IOObjectRelease(current)
            }

            guard result == KERN_SUCCESS else {
                return nil
            }

            if let bsdName = stringProperty(named: "BSD Name", for: parent) {
                IOObjectRelease(parent)
                return bsdName
            }

            current = parent
            ownsCurrent = true
        }
    }

    private struct IORegistryEvidence {
        let classPath: [String]
        let isPCITunnelled: Bool
    }

    private func ioRegistryEvidence(for service: io_service_t) -> IORegistryEvidence {
        var classes: [String] = []
        var isPCITunnelled = false
        var current = service
        var ownsCurrent = false

        while true {
            if let className = IOObjectCopyClass(current)?.takeRetainedValue() as String? {
                classes.append(className)
            }
            if boolProperty(named: "IOPCITunnelled", for: current) == true {
                isPCITunnelled = true
            }

            var parent: io_registry_entry_t = 0
            let result = IORegistryEntryGetParentEntry(current, "IOService", &parent)

            if ownsCurrent {
                IOObjectRelease(current)
            }

            guard result == KERN_SUCCESS else {
                return IORegistryEvidence(
                    classPath: classes,
                    isPCITunnelled: isPCITunnelled
                )
            }

            current = parent
            ownsCurrent = true
        }
    }

    private func stringProperty(named key: String, for service: io_service_t) -> String? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }

    private func boolProperty(named key: String, for service: io_service_t) -> Bool? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool
    }

    private func int64Property(named key: String, for service: io_service_t) -> Int64? {
        if let number = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber {
            return number.int64Value
        }

        return nil
    }

    private func registryEntryID(for service: io_service_t) -> UInt64? {
        var identifier: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &identifier) == KERN_SUCCESS else {
            return nil
        }
        return identifier
    }
}
