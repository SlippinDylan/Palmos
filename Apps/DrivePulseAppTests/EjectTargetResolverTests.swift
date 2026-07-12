import XCTest
@testable import DrivePulseApp

import DrivePulseCore

final class EjectTargetResolverTests: XCTestCase {
    func testResolvesFreshAPFSScopeFromStableDeviceIdentity() async throws {
        let adapter = SnapshotAdapter(snapshots: [[
            media(id: "serial:t7", bsd: "disk4", registryID: 4_001, children: ["disk4s1"], container: "disk5"),
            node(bsd: "disk4s1"),
            node(bsd: "disk5", children: ["disk5s1", "disk5s2"]),
            node(bsd: "disk5s1", mount: "/Volumes/Data"),
            node(bsd: "disk5s2", mount: "/Volumes/Data - Data")
        ]])
        let resolver = LiveEjectTargetResolver(snapshotProvider: adapter)

        let result = try await resolver.resolve(
            deviceID: DeviceID(rawValue: "serial:t7"),
            displayName: "Samsung T7",
            topologyGeneration: 9
        )

        XCTAssertEqual(result.target.physicalBSDName, "disk4")
        XCTAssertEqual(result.target.mediaRegistryEntryID, 4_001)
        XCTAssertEqual(result.scope.deviceNodes, Set(["/dev/disk4", "/dev/rdisk4", "/dev/disk4s1", "/dev/disk5", "/dev/disk5s1", "/dev/disk5s2"]))
        XCTAssertTrue(result.scope.contains(path: "/Volumes/Data/report.txt"))
        XCTAssertFalse(result.scope.contains(path: "/Volumes/Database/report.txt"))
    }

    func testResolvesOrdinaryPartitionDescendants() async throws {
        let adapter = SnapshotAdapter(snapshots: [[
            media(id: "serial:usb", bsd: "disk7", registryID: 7_001, children: ["disk7s1", "disk7s2"]),
            node(bsd: "disk7s1", mount: "/Volumes/EFI"),
            node(bsd: "disk7s2", mount: "/Volumes/Backup")
        ]])

        let result = try await LiveEjectTargetResolver(snapshotProvider: adapter).resolve(
            deviceID: DeviceID(rawValue: "serial:usb"), displayName: "Backup", topologyGeneration: 2
        )

        XCTAssertEqual(result.scope.deviceNodes, Set(["/dev/disk7", "/dev/rdisk7", "/dev/disk7s1", "/dev/disk7s2"]))
        XCTAssertEqual(result.scope.mountURLs, Set([URL(fileURLWithPath: "/Volumes/EFI"), URL(fileURLWithPath: "/Volumes/Backup")]))
    }

    func testRejectsDisappearedAndInternalMedia() async {
        let missing = LiveEjectTargetResolver(snapshotProvider: SnapshotAdapter(snapshots: [[]]))
        await XCTAssertThrowsErrorAsync(try await missing.resolve(deviceID: DeviceID(rawValue: "serial:x"), displayName: "X", topologyGeneration: 1))

        let internalMedia = media(id: "serial:x", bsd: "disk0", registryID: 1, isInternal: true)
        let internalResolver = LiveEjectTargetResolver(snapshotProvider: SnapshotAdapter(snapshots: [[internalMedia]]))
        await XCTAssertThrowsErrorAsync(try await internalResolver.resolve(deviceID: DeviceID(rawValue: "serial:x"), displayName: "X", topologyGeneration: 1))
    }

    func testRevalidationRejectsBSDReassignmentAndIdentityChanges() async throws {
        let original = media(id: "serial:t7", bsd: "disk4", registryID: 4_001)
        let cases = [
            media(id: "serial:t7", bsd: "disk4", registryID: 9_999),
            media(id: "serial:t7", bsd: "disk8", registryID: 4_001),
            media(id: "serial:other", bsd: "disk4", registryID: 4_001)
        ]

        for changed in cases {
            let resolver = LiveEjectTargetResolver(snapshotProvider: SnapshotAdapter(snapshots: [[original], [changed]]))
            let resolved = try await resolver.resolve(deviceID: DeviceID(rawValue: "serial:t7"), displayName: "T7", topologyGeneration: 3)
            await XCTAssertThrowsErrorAsync(try await resolver.revalidate(resolved.target))
        }
    }
}

private actor SnapshotAdapter: EjectTargetSnapshotProviding {
    private var snapshots: [[EjectMediaSnapshot]]
    init(snapshots: [[EjectMediaSnapshot]]) { self.snapshots = snapshots }
    func currentMedia() async -> [EjectMediaSnapshot] {
        snapshots.count > 1 ? snapshots.removeFirst() : (snapshots.first ?? [])
    }
}

private func media(
    id: String, bsd: String, registryID: UInt64, isInternal: Bool = false,
    children: [String] = [], container: String? = nil
) -> EjectMediaSnapshot {
    EjectMediaSnapshot(deviceID: DeviceID(rawValue: id), bsdName: bsd, registryEntryID: registryID,
                       isWhole: true, isInternal: isInternal, isEjectable: true,
                       childBSDNames: children, apfsContainerBSDName: container, mountURL: nil)
}

private func node(bsd: String, children: [String] = [], mount: String? = nil) -> EjectMediaSnapshot {
    EjectMediaSnapshot(deviceID: nil, bsdName: bsd, registryEntryID: nil, isWhole: false,
                       isInternal: false, isEjectable: false, childBSDNames: children,
                       apfsContainerBSDName: nil, mountURL: mount.map(URL.init(fileURLWithPath:)))
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
