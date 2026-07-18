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

    func testResolvesUnmountedExternalPhysicalDevice() async throws {
        let deviceID = DeviceID(rawValue: "session:test:registry:1b59")
        let adapter = SnapshotAdapter(snapshots: [[
            media(id: deviceID.rawValue, bsd: "disk9", registryID: 7_001)
        ]])

        let result = try await LiveEjectTargetResolver(snapshotProvider: adapter).resolve(
            deviceID: deviceID,
            displayName: "Unmounted SSD",
            topologyGeneration: 1
        )

        XCTAssertEqual(result.target.physicalBSDName, "disk9")
        XCTAssertEqual(result.scope.mountURLs, [])
        XCTAssertEqual(result.scope.deviceNodes, Set(["/dev/disk9", "/dev/rdisk9"]))
    }

    func testRejectsDisappearedAndInternalMedia() async {
        let missing = LiveEjectTargetResolver(snapshotProvider: SnapshotAdapter(snapshots: [[]]))
        await XCTAssertThrowsErrorAsync(try await missing.resolve(deviceID: DeviceID(rawValue: "serial:x"), displayName: "X", topologyGeneration: 1))

        let internalMedia = media(id: "serial:x", bsd: "disk0", registryID: 1, isExternal: false)
        let internalResolver = LiveEjectTargetResolver(snapshotProvider: SnapshotAdapter(snapshots: [[internalMedia]]))
        await XCTAssertThrowsErrorAsync(
            try await internalResolver.resolve(deviceID: DeviceID(rawValue: "serial:x"), displayName: "X", topologyGeneration: 1),
            equals: .unsafeMedia
        )

        let externallyManagedMedia = media(
            id: "serial:x",
            bsd: "disk2",
            registryID: 2,
            isEjectable: false
        )
        let externalResolver = LiveEjectTargetResolver(
            snapshotProvider: SnapshotAdapter(snapshots: [[externallyManagedMedia]])
        )
        let resolved = try? await externalResolver.resolve(
            deviceID: DeviceID(rawValue: "serial:x"),
            displayName: "X",
            topologyGeneration: 1
        )
        XCTAssertEqual(resolved?.target.physicalBSDName, "disk2")
    }

    func testRevalidationRejectsBSDReassignmentAndIdentityChanges() async throws {
        let original = media(id: "serial:t7", bsd: "disk4", registryID: 4_001)
        let cases: [(EjectMediaSnapshot, EjectTargetResolutionError)] = [
            (media(id: "serial:t7", bsd: "disk4", registryID: 9_999), .targetChanged),
            (media(id: "serial:t7", bsd: "disk8", registryID: 4_001), .targetChanged),
            (media(id: "serial:other", bsd: "disk4", registryID: 4_001), .deviceNotFound)
        ]

        for (changed, expectedError) in cases {
            let resolver = LiveEjectTargetResolver(snapshotProvider: SnapshotAdapter(snapshots: [[original], [changed]]))
            let resolved = try await resolver.resolve(deviceID: DeviceID(rawValue: "serial:t7"), displayName: "T7", topologyGeneration: 3)
            await XCTAssertThrowsErrorAsync(try await resolver.revalidate(resolved.target), equals: expectedError)
        }
    }

    func testConflictingChildRecordsCannotPolluteProviderScope() async throws {
        let provider = LiveEjectTargetSnapshotProvider(
            mapper: ExternalDeviceDiscoveryMapper(
                identityRegistry: DeviceIdentitySessionRegistry()
            )
        )
        let records = [
            discoveryRecord(
                bsdName: "disk4",
                parentBSDName: nil,
                isWholeMedia: true,
                registryEntryID: 4_001,
                mediaUUID: "media-a"
            ),
            discoveryRecord(
                bsdName: "disk4s1",
                parentBSDName: "disk4",
                wholeDiskBSDName: "disk4",
                volumePath: URL(fileURLWithPath: "/Volumes/First"),
                mediaName: "First"
            ),
            discoveryRecord(
                bsdName: "disk4s1",
                parentBSDName: "disk4",
                wholeDiskBSDName: "disk4",
                volumePath: URL(fileURLWithPath: "/Volumes/Second"),
                mediaName: "Second"
            )
        ]

        let snapshots = provider.snapshots(from: records)
        let root = try XCTUnwrap(snapshots.first(where: { $0.bsdName == "disk4" }))
        let deviceID = try XCTUnwrap(root.deviceID)
        XCTAssertEqual(snapshots.map(\.bsdName), ["disk4"])
        XCTAssertTrue(root.childBSDNames.isEmpty)

        let resolved = try await LiveEjectTargetResolver(
            snapshotProvider: SnapshotAdapter(snapshots: [snapshots])
        ).resolve(
            deviceID: deviceID,
            displayName: "External Disk",
            topologyGeneration: 1
        )

        XCTAssertEqual(resolved.scope.deviceNodes, Set(["/dev/disk4", "/dev/rdisk4"]))
        XCTAssertTrue(resolved.scope.mountURLs.isEmpty)
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
    id: String, bsd: String, registryID: UInt64, isExternal: Bool = true,
    isEjectable: Bool = true, children: [String] = [], container: String? = nil
) -> EjectMediaSnapshot {
    EjectMediaSnapshot(deviceID: DeviceID(rawValue: id), bsdName: bsd, registryEntryID: registryID,
                       isWhole: true, isExternal: isExternal, isEjectable: isEjectable,
                       childBSDNames: children, apfsContainerBSDName: container, mountURL: nil)
}

private func node(bsd: String, children: [String] = [], mount: String? = nil) -> EjectMediaSnapshot {
    EjectMediaSnapshot(deviceID: nil, bsdName: bsd, registryEntryID: nil, isWhole: false,
                       isExternal: false, isEjectable: false, childBSDNames: children,
                       apfsContainerBSDName: nil, mountURL: mount.map(URL.init(fileURLWithPath:)))
}

private func discoveryRecord(
    bsdName: String,
    parentBSDName: String?,
    wholeDiskBSDName: String? = nil,
    isWholeMedia: Bool = false,
    registryEntryID: UInt64? = nil,
    mediaUUID: String? = nil,
    volumePath: URL? = nil,
    mediaName: String = "Disk"
) -> DiskDiscoveryRecord {
    DiskDiscoveryRecord(
        bsdName: bsdName,
        parentBSDName: parentBSDName,
        wholeDiskBSDName: wholeDiskBSDName,
        deviceInternal: false,
        isNetworkVolume: false,
        isWholeMedia: isWholeMedia,
        isEjectable: true,
        registryEntryID: registryEntryID,
        volumePath: volumePath,
        mediaUUID: mediaUUID,
        mediaName: mediaName,
        deviceModel: nil,
        deviceVendor: nil,
        busName: "USB",
        deviceProtocol: "USB",
        capacityBytes: 1_000,
        mediaContent: nil,
        ioClassPath: ["IOMedia"]
    )
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

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    equals expectedError: EjectTargetResolutionError,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch let error as EjectTargetResolutionError {
        XCTAssertEqual(error, expectedError, file: file, line: line)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}
