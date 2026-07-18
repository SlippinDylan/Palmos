import XCTest
@testable import DrivePulseApp

import DrivePulseCore

final class ExternalDeviceDiscoveryMapperTests: XCTestCase {
    func testMapGroupsMountedVolumesUnderExternalPhysicalDevice() {
        let records = [
            DiskDiscoveryRecord(
                bsdName: "disk21",
                parentBSDName: nil,
                deviceInternal: false,
                isNetworkVolume: false,
                isWholeMedia: true,
                volumePath: nil,
                mediaUUID: "field-ssd",
                mediaName: "Field SSD",
                deviceModel: "Portable SSD",
                deviceVendor: "Acme",
                busName: "USB",
                deviceProtocol: "USB",
                capacityBytes: 2_000,
                mediaContent: nil,
                ioClassPath: ["IOUSBHostDevice", "IOMedia"]
            ),
            DiskDiscoveryRecord(
                bsdName: "disk21s1",
                parentBSDName: "disk21",
                deviceInternal: false,
                isNetworkVolume: false,
                isWholeMedia: false,
                volumePath: URL(fileURLWithPath: "/Volumes/Field SSD"),
                mediaName: "Field SSD",
                deviceModel: "Portable SSD",
                deviceVendor: "Acme",
                busName: "USB",
                deviceProtocol: "USB",
                capacityBytes: 1_000,
                mediaContent: "Apple_APFS",
                ioClassPath: ["IOUSBHostDevice", "IOMedia"]
            ),
            DiskDiscoveryRecord(
                bsdName: "disk99",
                parentBSDName: nil,
                deviceInternal: nil,
                isNetworkVolume: true,
                isWholeMedia: true,
                volumePath: URL(fileURLWithPath: "/Volumes/Network"),
                mediaName: "Network Share",
                deviceModel: nil,
                deviceVendor: nil,
                busName: "SMB",
                deviceProtocol: "SMB",
                capacityBytes: nil,
                mediaContent: nil,
                ioClassPath: ["IONetworkInterface"]
            )
        ]

        let devices = ExternalDeviceDiscoveryMapper().map(records)

        XCTAssertEqual(devices.count, 1)
        XCTAssertTrue(devices[0].id.rawValue.hasSuffix(":media:field-ssd"))
        XCTAssertEqual(devices[0].displayName, "Acme Portable SSD")
        XCTAssertEqual(devices[0].transportName, "USB")
        XCTAssertEqual(
            devices[0].volumes,
            [MountedVolume(bsdName: "disk21s1", mountPoint: "/Volumes/Field SSD")]
        )
    }

    func testMapKeepsExternalDeviceVisibleWithoutMountedVolumes() {
        let records = [
            DiskDiscoveryRecord(
                bsdName: "disk84",
                parentBSDName: nil,
                deviceInternal: false,
                isNetworkVolume: false,
                isWholeMedia: true,
                volumePath: nil,
                mediaUUID: "archive",
                mediaName: "Archive",
                deviceModel: nil,
                deviceVendor: nil,
                busName: "Thunderbolt",
                deviceProtocol: "Thunderbolt",
                capacityBytes: 4_000,
                mediaContent: nil,
                ioClassPath: ["AppleThunderboltPCIDownAdapter", "IOMedia"]
            )
        ]

        let devices = ExternalDeviceDiscoveryMapper().map(records)

        XCTAssertEqual(devices.count, 1)
        XCTAssertTrue(devices[0].id.rawValue.hasSuffix(":media:archive"))
        XCTAssertEqual(devices[0].transportName, "Thunderbolt")
        XCTAssertEqual(devices[0].volumes, [])
    }

    func testMapUsesDiskArbitrationWholeDiskRelationshipForMountedVolumes() {
        let records = [
            DiskDiscoveryRecord(
                bsdName: "disk21",
                parentBSDName: nil,
                deviceInternal: false,
                isNetworkVolume: false,
                isWholeMedia: true,
                volumePath: nil,
                mediaUUID: "capture",
                mediaName: "Capture",
                deviceModel: "Portable SSD",
                deviceVendor: "Acme",
                busName: "USB",
                deviceProtocol: "USB",
                capacityBytes: 2_000,
                mediaContent: nil,
                ioClassPath: ["IOUSBHostDevice", "IOMedia"]
            ),
            DiskDiscoveryRecord(
                bsdName: "disk50",
                parentBSDName: nil,
                deviceInternal: false,
                isNetworkVolume: false,
                isWholeMedia: true,
                volumePath: nil,
                mediaUUID: "archive-usb",
                mediaName: "Archive",
                deviceModel: "Portable SSD",
                deviceVendor: "Acme",
                busName: "USB",
                deviceProtocol: "USB",
                capacityBytes: 2_000,
                mediaContent: nil,
                ioClassPath: ["IOUSBHostDevice", "IOMedia"]
            ),
            DiskDiscoveryRecord(
                bsdName: "disk999s1",
                parentBSDName: "disk50",
                wholeDiskBSDName: "disk21",
                deviceInternal: false,
                isNetworkVolume: false,
                isWholeMedia: false,
                volumePath: URL(fileURLWithPath: "/Volumes/Capture"),
                mediaName: "Capture",
                deviceModel: nil,
                deviceVendor: nil,
                busName: "USB",
                deviceProtocol: "USB",
                capacityBytes: 1_000,
                mediaContent: "Apple_APFS",
                ioClassPath: ["IOUSBHostDevice", "IOMedia"]
            )
        ]

        let devices = ExternalDeviceDiscoveryMapper().map(records)

        XCTAssertEqual(devices.first(where: { $0.physicalStoreBSDName == "disk21" })?.volumes, [
            MountedVolume(bsdName: "disk999s1", mountPoint: "/Volumes/Capture")
        ])
        XCTAssertEqual(
            devices.first(where: { $0.physicalStoreBSDName == "disk50" })?.volumes,
            [MountedVolume]()
        )
    }

    func testMapIncludesMountedWholeDiskRootAsVolume() {
        let records = [
            DiskDiscoveryRecord(
                bsdName: "disk3",
                parentBSDName: nil,
                wholeDiskBSDName: "disk3",
                deviceInternal: false,
                isNetworkVolume: false,
                isWholeMedia: true,
                volumePath: URL(fileURLWithPath: "/Volumes/CAMERA_CARD"),
                mediaUUID: "camera-card",
                mediaName: "CAMERA_CARD",
                deviceModel: nil,
                deviceVendor: "Acme",
                busName: "SD",
                deviceProtocol: "SD",
                capacityBytes: 256_000,
                mediaContent: "DOS_FAT_32",
                ioClassPath: ["IOSDHostDevice", "IOMedia"]
            )
        ]

        let devices = ExternalDeviceDiscoveryMapper().map(records)

        XCTAssertEqual(devices.count, 1)
        XCTAssertTrue(devices[0].id.rawValue.hasSuffix(":media:camera-card"))
        XCTAssertEqual(devices[0].transportName, "SD")
        XCTAssertEqual(
            devices[0].volumes,
            [MountedVolume(bsdName: "disk3", mountPoint: "/Volumes/CAMERA_CARD")]
        )
    }

    func testMapCapturesAPFSContainerBSDName() {
        let records = [
            DiskDiscoveryRecord(
                bsdName: "disk7",
                parentBSDName: nil,
                deviceInternal: false,
                isNetworkVolume: false,
                isWholeMedia: true,
                volumePath: nil,
                mediaUUID: "backup",
                mediaName: "Backup",
                deviceModel: "Mini",
                deviceVendor: "Acme",
                busName: "USB4",
                deviceProtocol: "USB4",
                capacityBytes: 4_000,
                mediaContent: nil,
                ioClassPath: ["IOUSBHostDevice", "IOMedia"]
            ),
            DiskDiscoveryRecord(
                bsdName: "disk8",
                parentBSDName: "disk7",
                deviceInternal: false,
                isNetworkVolume: false,
                isWholeMedia: true,
                volumePath: nil,
                mediaName: "Container",
                deviceModel: nil,
                deviceVendor: nil,
                busName: "USB4",
                deviceProtocol: "USB4",
                capacityBytes: 4_000,
                mediaContent: "Apple_APFS",
                ioClassPath: ["IOUSBHostDevice", "IOMedia"]
            ),
            DiskDiscoveryRecord(
                bsdName: "disk8s1",
                parentBSDName: "disk8",
                deviceInternal: false,
                isNetworkVolume: false,
                isWholeMedia: false,
                volumePath: URL(fileURLWithPath: "/Volumes/Backup"),
                mediaName: "Backup",
                deviceModel: nil,
                deviceVendor: nil,
                busName: "USB4",
                deviceProtocol: "USB4",
                capacityBytes: 2_000,
                mediaContent: "Apple_APFS",
                ioClassPath: ["IOUSBHostDevice", "IOMedia"]
            )
        ]

        let devices = ExternalDeviceDiscoveryMapper().map(records)

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].apfsContainerBSDName, "disk8")
        XCTAssertEqual(
            devices[0].volumes,
            [MountedVolume(bsdName: "disk8s1", mountPoint: "/Volumes/Backup")]
        )
    }

    func testMapUsesMediaUUIDAcrossBSDNameReuse() {
        let mapper = ExternalDeviceDiscoveryMapper()
        let first = DiskDiscoveryRecord(
            bsdName: "disk4", parentBSDName: nil, deviceInternal: false,
            isNetworkVolume: false, isWholeMedia: true, volumePath: nil,
            mediaUUID: "same-media", mediaName: "Disk", deviceModel: nil,
            deviceVendor: nil, busName: "USB", deviceProtocol: "USB",
            capacityBytes: 1_000, mediaContent: nil, ioClassPath: []
        )
        let replacement = DiskDiscoveryRecord(
            bsdName: "disk8", parentBSDName: nil, deviceInternal: false,
            isNetworkVolume: false, isWholeMedia: true, volumePath: nil,
            mediaUUID: "same-media", mediaName: "Disk", deviceModel: nil,
            deviceVendor: nil, busName: "USB", deviceProtocol: "USB",
            capacityBytes: 1_000, mediaContent: nil, ioClassPath: []
        )

        let firstID = mapper.map([first]).first?.id
        let replacementID = mapper.map([replacement]).first?.id
        XCTAssertEqual(firstID, replacementID)
        XCTAssertTrue(firstID?.rawValue.hasSuffix(":media:same-media") == true)
    }

    func testMapStartsNewSessionAfterMediaDisappears() {
        let mapper = ExternalDeviceDiscoveryMapper()
        let record = DiskDiscoveryRecord(
            bsdName: "disk4", parentBSDName: nil, deviceInternal: false,
            isNetworkVolume: false, isWholeMedia: true, volumePath: nil,
            mediaUUID: "same-media", mediaName: "Disk", deviceModel: nil,
            deviceVendor: nil, busName: "USB", deviceProtocol: "USB",
            capacityBytes: 1_000, mediaContent: nil, ioClassPath: []
        )

        let firstID = mapper.map([record]).first?.id
        XCTAssertTrue(mapper.map([]).isEmpty)
        let reinsertedID = mapper.map([record]).first?.id

        XCTAssertNotEqual(firstID, reinsertedID)
    }

    func testMapDoesNotUseBSDNameAsFallbackIdentity() {
        let mapper = ExternalDeviceDiscoveryMapper()
        let record = DiskDiscoveryRecord(
            bsdName: "disk4", parentBSDName: nil, deviceInternal: false,
            isNetworkVolume: false, isWholeMedia: true, volumePath: nil,
            mediaName: "Disk", deviceModel: nil, deviceVendor: nil,
            busName: "USB", deviceProtocol: "USB", capacityBytes: 1_000,
            mediaContent: nil, ioClassPath: []
        )

        let id = mapper.map([record]).first?.id
        XCTAssertNotEqual(id, DeviceID(rawValue: "disk4"))
        XCTAssertTrue(id?.rawValue.hasPrefix("session:") == true)
    }

    func testMapDisambiguatesDuplicateMediaUUIDEvidence() {
        let records = [
            DiskDiscoveryRecord(
                bsdName: "disk4", parentBSDName: nil, deviceInternal: false,
                isNetworkVolume: false, isWholeMedia: true, volumePath: nil,
                mediaUUID: "duplicate", mediaName: "One", deviceModel: nil,
                deviceVendor: nil, busName: "USB", deviceProtocol: "USB",
                capacityBytes: 1_000, mediaContent: nil, ioClassPath: []
            ),
            DiskDiscoveryRecord(
                bsdName: "disk8", parentBSDName: nil, deviceInternal: false,
                isNetworkVolume: false, isWholeMedia: true, volumePath: nil,
                mediaUUID: "duplicate", mediaName: "Two", deviceModel: nil,
                deviceVendor: nil, busName: "USB", deviceProtocol: "USB",
                capacityBytes: 1_000, mediaContent: nil, ioClassPath: []
            )
        ]

        let devices = ExternalDeviceDiscoveryMapper().map(records)
        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(Set(devices.map(\.id)).count, 2)
    }

    func testDuplicateMediaUUIDKeepsRemainingDeviceSessionIdentity() throws {
        let mapper = ExternalDeviceDiscoveryMapper()
        let first = physicalRecord(bsdName: "disk4", mediaUUID: "duplicate")
        let second = physicalRecord(bsdName: "disk8", mediaUUID: "duplicate")

        let initial = mapper.map([first, second])
        let firstID = try XCTUnwrap(
            initial.first(where: { $0.physicalStoreBSDName == "disk4" })?.id
        )
        let secondID = try XCTUnwrap(
            initial.first(where: { $0.physicalStoreBSDName == "disk8" })?.id
        )
        let afterRemoval = mapper.map([second])

        XCTAssertNotEqual(firstID, secondID)
        XCTAssertEqual(afterRemoval.first?.id, secondID)
        XCTAssertNotEqual(afterRemoval.first?.id, firstID)
    }

    func testMapDropsConflictingDuplicateBSDRecords() {
        let records = [
            physicalRecord(bsdName: "disk4", mediaUUID: "first"),
            physicalRecord(bsdName: "disk4", mediaUUID: "second")
        ]

        XCTAssertEqual(ExternalDeviceDiscoveryMapper().map(records), [])
    }

    func testMapCoalescesIdenticalDuplicateBSDRecords() {
        let record = physicalRecord(bsdName: "disk4", mediaUUID: "same")

        let devices = ExternalDeviceDiscoveryMapper().map([record, record])

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.physicalStoreBSDName, "disk4")
    }

    func testDiscoveryAndEjectMappersShareUnmountedDeviceIdentity() throws {
        let registry = DeviceIdentitySessionRegistry()
        let discoveryMapper = ExternalDeviceDiscoveryMapper(identityRegistry: registry)
        let ejectMapper = ExternalDeviceDiscoveryMapper(identityRegistry: registry)
        let unmounted = physicalRecord(bsdName: "disk9", mediaUUID: "unmounted")

        let discoveredID = try XCTUnwrap(discoveryMapper.map([unmounted]).first?.id)
        let ejectSnapshotID = try XCTUnwrap(ejectMapper.map([unmounted]).first?.id)

        XCTAssertEqual(ejectSnapshotID, discoveredID)
    }

    func testRegistryIdentityWinsWhenDeviceMovesOntoAnotherDevicesBSDName() throws {
        let mapper = ExternalDeviceDiscoveryMapper()
        let deviceA = physicalRecord(
            bsdName: "disk4",
            mediaUUID: "media-a",
            registryEntryID: 4_001
        )
        let deviceB = physicalRecord(
            bsdName: "disk8",
            mediaUUID: "media-b",
            registryEntryID: 8_001
        )
        let initial = mapper.map([deviceA, deviceB])
        let deviceAID = try XCTUnwrap(
            initial.first(where: { $0.physicalStoreBSDName == "disk4" })?.id
        )
        let deviceBID = try XCTUnwrap(
            initial.first(where: { $0.physicalStoreBSDName == "disk8" })?.id
        )
        let movedDeviceB = physicalRecord(
            bsdName: "disk4",
            mediaUUID: "media-b",
            registryEntryID: 8_001
        )

        let moved = try XCTUnwrap(mapper.map([movedDeviceB]).first)

        XCTAssertEqual(moved.id, deviceBID)
        XCTAssertNotEqual(moved.id, deviceAID)
    }

    func testDuplicateMediaUUIDSurvivorKeepsIdentityAfterLaterBSDChange() throws {
        let mapper = ExternalDeviceDiscoveryMapper()
        let first = physicalRecord(bsdName: "disk4", mediaUUID: "duplicate")
        let survivor = physicalRecord(bsdName: "disk8", mediaUUID: "duplicate")
        let initial = mapper.map([first, survivor])
        let survivorID = try XCTUnwrap(
            initial.first(where: { $0.physicalStoreBSDName == "disk8" })?.id
        )

        _ = mapper.map([survivor])
        let movedSurvivor = physicalRecord(bsdName: "disk10", mediaUUID: "duplicate")
        let moved = try XCTUnwrap(mapper.map([movedSurvivor]).first)

        XCTAssertEqual(moved.id, survivorID)
    }

    func testStableIncomingEvidenceDoesNotReuseSparseSessionAtSameBSDName() throws {
        let mapper = ExternalDeviceDiscoveryMapper()
        let sparse = physicalRecord(bsdName: "disk4", mediaUUID: nil)
        let sparseID = try XCTUnwrap(mapper.map([sparse]).first?.id)
        let identified = physicalRecord(
            bsdName: "disk4",
            mediaUUID: "identified",
            registryEntryID: 4_001
        )

        let identifiedID = try XCTUnwrap(mapper.map([identified]).first?.id)

        XCTAssertNotEqual(identifiedID, sparseID)
    }

    func testDifferentMediaEvidenceDoesNotReuseSessionAtSameBSDName() throws {
        let mapper = ExternalDeviceDiscoveryMapper()
        let first = physicalRecord(bsdName: "disk4", mediaUUID: "media-a")
        let firstID = try XCTUnwrap(mapper.map([first]).first?.id)
        let replacement = physicalRecord(bsdName: "disk4", mediaUUID: "media-b")

        let replacementID = try XCTUnwrap(mapper.map([replacement]).first?.id)

        XCTAssertNotEqual(replacementID, firstID)
    }

    func testTransientIdentityEvidenceLossKeepsResolvedDeviceID() throws {
        let mapper = ExternalDeviceDiscoveryMapper()
        let identified = physicalRecord(
            bsdName: "disk4",
            mediaUUID: "media-a",
            registryEntryID: 4_001
        )
        let identifiedID = try XCTUnwrap(mapper.map([identified]).first?.id)
        let sparseObservation = physicalRecord(bsdName: "disk4", mediaUUID: nil)

        let sparseID = try XCTUnwrap(mapper.map([sparseObservation]).first?.id)

        XCTAssertEqual(sparseID, identifiedID)
    }

    func testDuplicateCurrentRegistryEvidenceCannotClaimPreviousSession() throws {
        let mapper = ExternalDeviceDiscoveryMapper()
        let original = physicalRecord(
            bsdName: "disk4",
            mediaUUID: nil,
            registryEntryID: 4_001
        )
        let originalID = try XCTUnwrap(mapper.map([original]).first?.id)
        let duplicateRegistryRecords = [
            physicalRecord(bsdName: "disk8", mediaUUID: nil, registryEntryID: 4_001),
            physicalRecord(bsdName: "disk10", mediaUUID: nil, registryEntryID: 4_001)
        ]

        let replacements = mapper.map(duplicateRegistryRecords)

        XCTAssertEqual(replacements.count, 2)
        XCTAssertEqual(Set(replacements.map(\.id)).count, 2)
        XCTAssertFalse(replacements.contains(where: { $0.id == originalID }))
    }

    func testConflictingWholeRootDropsEntireDescendantTopology() {
        let firstRoot = physicalRecord(bsdName: "disk4", mediaUUID: "first")
        let secondRoot = physicalRecord(bsdName: "disk4", mediaUUID: "second")
        let container = apfsRecord(bsdName: "disk5", parentBSDName: "disk4")
        let volume = volumeRecord(bsdName: "disk5s1", parentBSDName: "disk5")

        XCTAssertEqual(
            ExternalDeviceDiscoveryMapper().map([firstRoot, secondRoot, container, volume]),
            []
        )
    }

    func testConflictingAPFSChildDropsOnlyAmbiguousSubtree() throws {
        let root = physicalRecord(bsdName: "disk4", mediaUUID: "root")
        let firstContainer = apfsRecord(
            bsdName: "disk5",
            parentBSDName: "disk4",
            mediaName: "First"
        )
        let secondContainer = apfsRecord(
            bsdName: "disk5",
            parentBSDName: "disk4",
            mediaName: "Second"
        )
        let volume = volumeRecord(bsdName: "disk5s1", parentBSDName: "disk5")

        let device = try XCTUnwrap(
            ExternalDeviceDiscoveryMapper().map([
                root, firstContainer, secondContainer, volume
            ]).first
        )

        XCTAssertEqual(device.physicalStoreBSDName, "disk4")
        XCTAssertNil(device.apfsContainerBSDName)
        XCTAssertTrue(device.volumes.isEmpty)
    }
}

private func physicalRecord(
    bsdName: String,
    mediaUUID: String?,
    registryEntryID: UInt64? = nil
) -> DiskDiscoveryRecord {
    DiskDiscoveryRecord(
        bsdName: bsdName,
        parentBSDName: nil,
        deviceInternal: false,
        isNetworkVolume: false,
        isWholeMedia: true,
        registryEntryID: registryEntryID,
        volumePath: nil,
        mediaUUID: mediaUUID,
        mediaName: "Disk",
        deviceModel: nil,
        deviceVendor: nil,
        busName: "USB",
        deviceProtocol: "USB",
        capacityBytes: 1_000,
        mediaContent: nil,
        ioClassPath: []
    )
}

private func apfsRecord(
    bsdName: String,
    parentBSDName: String,
    mediaName: String = "Container"
) -> DiskDiscoveryRecord {
    DiskDiscoveryRecord(
        bsdName: bsdName,
        parentBSDName: parentBSDName,
        deviceInternal: false,
        isNetworkVolume: false,
        isWholeMedia: true,
        volumePath: nil,
        mediaName: mediaName,
        deviceModel: nil,
        deviceVendor: nil,
        busName: "USB",
        deviceProtocol: "USB",
        capacityBytes: 1_000,
        mediaContent: "Apple_APFS",
        ioClassPath: ["IOMedia"]
    )
}

private func volumeRecord(
    bsdName: String,
    parentBSDName: String
) -> DiskDiscoveryRecord {
    DiskDiscoveryRecord(
        bsdName: bsdName,
        parentBSDName: parentBSDName,
        deviceInternal: false,
        isNetworkVolume: false,
        isWholeMedia: false,
        volumePath: URL(fileURLWithPath: "/Volumes/Test"),
        mediaName: "Test",
        deviceModel: nil,
        deviceVendor: nil,
        busName: "USB",
        deviceProtocol: "USB",
        capacityBytes: 500,
        mediaContent: "Apple_APFS",
        ioClassPath: ["IOMedia"]
    )
}
