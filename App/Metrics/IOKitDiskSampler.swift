import Foundation
import IOKit
import IOKit.storage

struct DiskIOCounters: Equatable, Sendable {
    let readBytes: Int64
    let writeBytes: Int64
}

protocol DiskSampling: Sendable {
    func counters(forBSDName bsdName: String) -> DiskIOCounters?
    func invalidateCachedServices()
}

extension DiskSampling {
    func invalidateCachedServices() {}
}

/// Owns the service returned by `matchingService` and balances every retain and
/// release performed by the sampler.
protocol IOKitDiskServiceOperating: Sendable {
    func matchingService(forBSDName bsdName: String) -> io_service_t?
    func retain(_ service: io_service_t) -> Bool
    func release(_ service: io_service_t)
    func statistics(for service: io_service_t) -> NSDictionary?
}

// `cacheLock` protects every access to the mutable service cache; borrowed
// services hold an independent IOKit reference while used outside the lock.
final class IOKitDiskSampler: DiskSampling, @unchecked Sendable {
    private let operations: any IOKitDiskServiceOperating
    private let cacheLock = NSLock()
    private var cachedServicesByBSDName: [String: io_service_t] = [:]

    init(operations: any IOKitDiskServiceOperating = LiveIOKitDiskServiceOperations()) {
        self.operations = operations
    }

    deinit {
        releaseAllCachedServices()
    }

    func counters(forBSDName bsdName: String) -> DiskIOCounters? {
        for _ in 0..<2 {
            guard let service = borrowService(forBSDName: bsdName) else {
                return nil
            }

            let counters = readCounters(from: service)
            operations.release(service)

            if let counters {
                return counters
            }

            // A registry service can become stale after an unplug, remount, or
            // BSD-name reuse. Drop only the entry that produced this failure so
            // a concurrent topology invalidation cannot lose a newer service.
            invalidateCachedService(forBSDName: bsdName, matching: service)
        }

        return nil
    }

    func invalidateCachedServices() {
        releaseAllCachedServices()
    }

    private func borrowService(forBSDName bsdName: String) -> io_service_t? {
        cacheLock.withLock {
            if let cachedService = cachedServicesByBSDName[bsdName] {
                if operations.retain(cachedService) {
                    return cachedService
                }

                cachedServicesByBSDName.removeValue(forKey: bsdName)
                operations.release(cachedService)
            }

            guard let matchedService = operations.matchingService(forBSDName: bsdName) else {
                return nil
            }
            guard operations.retain(matchedService) else {
                operations.release(matchedService)
                return nil
            }

            cachedServicesByBSDName[bsdName] = matchedService
            return matchedService
        }
    }

    private func invalidateCachedService(forBSDName bsdName: String, matching service: io_service_t) {
        let removedService = cacheLock.withLock { () -> io_service_t? in
            guard cachedServicesByBSDName[bsdName] == service else {
                return nil
            }
            return cachedServicesByBSDName.removeValue(forKey: bsdName)
        }

        if let removedService {
            operations.release(removedService)
        }
    }

    private func releaseAllCachedServices() {
        let services = cacheLock.withLock {
            let services = Array(cachedServicesByBSDName.values)
            cachedServicesByBSDName.removeAll()
            return services
        }
        services.forEach(operations.release)
    }

    private func readCounters(from service: io_service_t) -> DiskIOCounters? {
        guard let statistics = operations.statistics(for: service),
              let readBytes = numberValue(
                  forKey: kIOBlockStorageDriverStatisticsBytesReadKey,
                  in: statistics
              ),
              let writeBytes = numberValue(
                  forKey: kIOBlockStorageDriverStatisticsBytesWrittenKey,
                  in: statistics
              ) else {
            return nil
        }

        return DiskIOCounters(readBytes: readBytes, writeBytes: writeBytes)
    }

    private func numberValue(forKey key: String, in dictionary: NSDictionary) -> Int64? {
        (dictionary[key] as? NSNumber)?.int64Value
    }
}

private struct LiveIOKitDiskServiceOperations: IOKitDiskServiceOperating {
    func matchingService(forBSDName bsdName: String) -> io_service_t? {
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
        return service == IO_OBJECT_NULL ? nil : service
    }

    func retain(_ service: io_service_t) -> Bool {
        IOObjectRetain(service) == KERN_SUCCESS
    }

    func release(_ service: io_service_t) {
        IOObjectRelease(service)
    }

    func statistics(for service: io_service_t) -> NSDictionary? {
        IORegistryEntrySearchCFProperty(
            service,
            kIOServicePlane,
            kIOBlockStorageDriverStatisticsKey as CFString,
            kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateParents | kIORegistryIterateRecursively)
        ) as? NSDictionary
    }
}
