import Foundation
import IOKit
import IOKit.storage
import XCTest

@testable import PalmosApp

final class IOKitDiskSamplerTests: XCTestCase {
    func testRepeatedReadsReuseOneMatchedService() {
        let operations = IOKitDiskServiceOperationsProbe(
            matches: ["disk4": [41]],
            statistics: [41: [Self.statistics(read: 10, written: 20)]]
        )
        let sampler = IOKitDiskSampler(operations: operations)

        XCTAssertEqual(
            sampler.counters(forBSDName: "disk4"),
            DiskIOCounters(readBytes: 10, writeBytes: 20)
        )
        XCTAssertEqual(
            sampler.counters(forBSDName: "disk4"),
            DiskIOCounters(readBytes: 10, writeBytes: 20)
        )
        XCTAssertEqual(operations.matchCount(for: "disk4"), 1)
    }

    func testReadFailureInvalidatesAndRematchesOnlyOnce() {
        let operations = IOKitDiskServiceOperationsProbe(
            matches: ["disk4": [41, 42]],
            statistics: [41: [nil], 42: [nil]]
        )
        let sampler = IOKitDiskSampler(operations: operations)

        XCTAssertNil(sampler.counters(forBSDName: "disk4"))
        XCTAssertEqual(operations.matchCount(for: "disk4"), 2)
        XCTAssertEqual(operations.outstandingReferenceCount(for: 41), 0)
        XCTAssertEqual(operations.outstandingReferenceCount(for: 42), 0)
    }

    func testReadFailureRematchesAndReturnsReplacementCounters() {
        let operations = IOKitDiskServiceOperationsProbe(
            matches: ["disk4": [41, 42]],
            statistics: [
                41: [nil],
                42: [Self.statistics(read: 30, written: 40)]
            ]
        )
        let sampler = IOKitDiskSampler(operations: operations)

        XCTAssertEqual(
            sampler.counters(forBSDName: "disk4"),
            DiskIOCounters(readBytes: 30, writeBytes: 40)
        )
        XCTAssertEqual(operations.matchCount(for: "disk4"), 2)
        XCTAssertEqual(operations.outstandingReferenceCount(for: 41), 0)
    }

    func testTopologyInvalidationPreventsBSDReuseFromUsingOldService() {
        let operations = IOKitDiskServiceOperationsProbe(
            matches: ["disk4": [41, 42]],
            statistics: [
                41: [Self.statistics(read: 10, written: 20)],
                42: [Self.statistics(read: 100, written: 200)]
            ]
        )
        let sampler = IOKitDiskSampler(operations: operations)

        XCTAssertEqual(
            sampler.counters(forBSDName: "disk4"),
            DiskIOCounters(readBytes: 10, writeBytes: 20)
        )
        sampler.invalidateCachedServices()
        XCTAssertEqual(operations.outstandingReferenceCount(for: 41), 0)
        XCTAssertEqual(
            sampler.counters(forBSDName: "disk4"),
            DiskIOCounters(readBytes: 100, writeBytes: 200)
        )
        XCTAssertEqual(operations.matchCount(for: "disk4"), 2)
    }

    func testConcurrentReadsShareOneCachedService() {
        let operations = IOKitDiskServiceOperationsProbe(
            matches: ["disk4": [41]],
            statistics: [41: [Self.statistics(read: 10, written: 20)]]
        )
        let sampler = IOKitDiskSampler(operations: operations)

        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            XCTAssertNotNil(sampler.counters(forBSDName: "disk4"))
        }

        XCTAssertEqual(operations.matchCount(for: "disk4"), 1)
    }

    func testDeinitReleasesEveryCachedService() {
        let operations = IOKitDiskServiceOperationsProbe(
            matches: ["disk4": [41], "disk5": [51]],
            statistics: [
                41: [Self.statistics(read: 10, written: 20)],
                51: [Self.statistics(read: 30, written: 40)]
            ]
        )
        var sampler: IOKitDiskSampler? = IOKitDiskSampler(operations: operations)

        XCTAssertNotNil(sampler?.counters(forBSDName: "disk4"))
        XCTAssertNotNil(sampler?.counters(forBSDName: "disk5"))
        sampler = nil

        XCTAssertEqual(operations.outstandingReferenceCount(for: 41), 0)
        XCTAssertEqual(operations.outstandingReferenceCount(for: 51), 0)
    }

    private static func statistics(read: Int64, written: Int64) -> NSDictionary {
        [
            kIOBlockStorageDriverStatisticsBytesReadKey: NSNumber(value: read),
            kIOBlockStorageDriverStatisticsBytesWrittenKey: NSNumber(value: written)
        ]
    }
}

private final class IOKitDiskServiceOperationsProbe: IOKitDiskServiceOperating, @unchecked Sendable {
    private let lock = NSLock()
    private var matches: [String: [io_service_t]]
    private var statisticsByService: [io_service_t: [NSDictionary?]]
    private var matchCounts: [String: Int] = [:]
    private var referenceCounts: [io_service_t: Int] = [:]

    init(matches: [String: [io_service_t]], statistics: [io_service_t: [NSDictionary?]]) {
        self.matches = matches
        self.statisticsByService = statistics
    }

    func matchingService(forBSDName bsdName: String) -> io_service_t? {
        lock.withLock {
            matchCounts[bsdName, default: 0] += 1
            guard var services = matches[bsdName], services.isEmpty == false else {
                return nil
            }
            let service = services.removeFirst()
            matches[bsdName] = services
            referenceCounts[service, default: 0] += 1
            return service
        }
    }

    func retain(_ service: io_service_t) -> Bool {
        lock.withLock {
            guard referenceCounts[service, default: 0] > 0 else { return false }
            referenceCounts[service, default: 0] += 1
            return true
        }
    }

    func release(_ service: io_service_t) {
        lock.withLock {
            referenceCounts[service, default: 0] -= 1
        }
    }

    func statistics(for service: io_service_t) -> NSDictionary? {
        lock.withLock {
            guard var values = statisticsByService[service], values.isEmpty == false else {
                return nil
            }
            let value = values.count == 1 ? values[0] : values.removeFirst()
            statisticsByService[service] = values
            return value
        }
    }

    func matchCount(for bsdName: String) -> Int {
        lock.withLock { matchCounts[bsdName, default: 0] }
    }

    func outstandingReferenceCount(for service: io_service_t) -> Int {
        lock.withLock { referenceCounts[service, default: 0] }
    }
}
