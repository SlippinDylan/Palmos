import Foundation
import IOKit
import IOKit.storage

struct DiskIOCounters: Equatable, Sendable {
    let readBytes: Int64
    let writeBytes: Int64
}

protocol DiskSampling: Sendable {
    func counters(forBSDName bsdName: String) -> DiskIOCounters?
}

struct IOKitDiskSampler: DiskSampling {
    func counters(forBSDName bsdName: String) -> DiskIOCounters? {
        guard let service = matchingService(forBSDName: bsdName) else {
            return nil
        }
        defer { IOObjectRelease(service) }

        guard let statistics = IORegistryEntrySearchCFProperty(
            service,
            kIOServicePlane,
            kIOBlockStorageDriverStatisticsKey as CFString,
            kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateParents | kIORegistryIterateRecursively)
        ) as? NSDictionary else {
            return nil
        }

        guard let readBytes = numberValue(
            forKey: kIOBlockStorageDriverStatisticsBytesReadKey,
            in: statistics
        ), let writeBytes = numberValue(
            forKey: kIOBlockStorageDriverStatisticsBytesWrittenKey,
            in: statistics
        ) else {
            return nil
        }

        return DiskIOCounters(
            readBytes: readBytes,
            writeBytes: writeBytes
        )
    }

    private func matchingService(forBSDName bsdName: String) -> io_service_t? {
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else {
            return nil
        }

        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard result == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        let service = IOIteratorNext(iterator)
        guard service != 0 else {
            return nil
        }

        return service
    }

    private func numberValue(forKey key: String, in dictionary: NSDictionary) -> Int64? {
        (dictionary[key] as? NSNumber)?.int64Value
    }
}
