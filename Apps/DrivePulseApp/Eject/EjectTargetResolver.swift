import DiskArbitration
import Foundation

import DrivePulseCore

struct ResolvedEjectTarget: Equatable, Sendable {
    let target: EjectWorkflowTarget
    let scope: OccupancyTargetScope
}

protocol EjectTargetResolving: Sendable {
    func resolve(
        deviceID: DeviceID,
        displayName: String,
        topologyGeneration: Int
    ) async throws -> ResolvedEjectTarget

    func revalidate(_ target: EjectWorkflowTarget) async throws -> ResolvedEjectTarget
}

enum EjectTargetResolutionError: Error, Equatable {
    case deviceNotFound
    case unsafeMedia
    case incompleteMediaIdentity
    case targetChanged
}

/// A target-scoped, current topology record derived by the platform adapter.
struct EjectMediaSnapshot: Equatable, Sendable {
    let deviceID: DeviceID?
    let bsdName: String
    let registryEntryID: UInt64?
    let isWhole: Bool
    let isExternal: Bool
    let isEjectable: Bool
    let childBSDNames: [String]
    let apfsContainerBSDName: String?
    let mountURL: URL?
}

/// Implementations enumerate live Disk Arbitration and IOKit state on every call.
protocol EjectTargetSnapshotProviding: Sendable {
    func currentMedia() async throws -> [EjectMediaSnapshot]
}

struct LiveEjectTargetSnapshotProvider: EjectTargetSnapshotProviding {
    private let mapper: ExternalDeviceDiscoveryMapper

    init(mapper: ExternalDeviceDiscoveryMapper = ExternalDeviceDiscoveryMapper()) {
        self.mapper = mapper
    }

    func currentMedia() async throws -> [EjectMediaSnapshot] {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return [] }

        let records = DiskDiscoveryEnumerator(session: session).records()
        let devices = mapper.map(records)
        let devicesByBSDName = Dictionary(uniqueKeysWithValues: devices.map { ($0.physicalStoreBSDName, $0) })
        let childNamesByParent = Dictionary(grouping: records, by: \DiskDiscoveryRecord.parentBSDName)

        return records.map { record in
            let device = devicesByBSDName[record.bsdName]
            return EjectMediaSnapshot(
                deviceID: device?.id,
                bsdName: record.bsdName,
                registryEntryID: record.registryEntryID,
                isWhole: record.isWholeMedia,
                isExternal: DeviceIdentityResolver.isExternalPhysicalDevice(record.descriptor),
                isEjectable: record.isEjectable,
                childBSDNames: (childNamesByParent[record.bsdName] ?? []).map(\.bsdName),
                apfsContainerBSDName: device?.apfsContainerBSDName,
                mountURL: record.volumePath
            )
        }
    }
}

struct LiveEjectTargetResolver: EjectTargetResolving {
    private let snapshotProvider: any EjectTargetSnapshotProviding

    init(snapshotProvider: any EjectTargetSnapshotProviding) {
        self.snapshotProvider = snapshotProvider
    }

    init() {
        self.init(snapshotProvider: LiveEjectTargetSnapshotProvider())
    }

    func resolve(
        deviceID: DeviceID,
        displayName: String,
        topologyGeneration: Int
    ) async throws -> ResolvedEjectTarget {
        let media = try await snapshotProvider.currentMedia()
        return try resolvedTarget(
            matching: deviceID,
            displayName: displayName,
            topologyGeneration: topologyGeneration,
            media: media
        )
    }

    func revalidate(_ target: EjectWorkflowTarget) async throws -> ResolvedEjectTarget {
        let media = try await snapshotProvider.currentMedia()
        let current = try resolvedTarget(
            matching: target.deviceID,
            displayName: target.displayName,
            topologyGeneration: target.topologyGeneration,
            media: media
        )

        guard current.target.physicalBSDName == target.physicalBSDName,
              current.target.mediaRegistryEntryID == target.mediaRegistryEntryID else {
            throw EjectTargetResolutionError.targetChanged
        }

        return current
    }

    private func resolvedTarget(
        matching deviceID: DeviceID,
        displayName: String,
        topologyGeneration: Int,
        media: [EjectMediaSnapshot]
    ) throws -> ResolvedEjectTarget {
        guard let wholeMedia = media.first(where: { $0.isWhole && $0.deviceID == deviceID }) else {
            throw EjectTargetResolutionError.deviceNotFound
        }
        // Disk Arbitration is the authority on whether an external disk can be
        // unmounted/ejected. Some devices Finder can eject do not advertise the
        // optional ejectable description flag on their whole-media object.
        guard wholeMedia.isExternal else {
            throw EjectTargetResolutionError.unsafeMedia
        }
        guard wholeMedia.bsdName.isEmpty == false, let registryEntryID = wholeMedia.registryEntryID else {
            throw EjectTargetResolutionError.incompleteMediaIdentity
        }

        let target = EjectWorkflowTarget(
            deviceID: deviceID,
            physicalBSDName: wholeMedia.bsdName,
            mediaRegistryEntryID: registryEntryID,
            displayName: displayName,
            topologyGeneration: topologyGeneration
        )
        return ResolvedEjectTarget(target: target, scope: scope(for: wholeMedia, media: media))
    }

    private func scope(
        for wholeMedia: EjectMediaSnapshot,
        media: [EjectMediaSnapshot]
    ) -> OccupancyTargetScope {
        let recordsByBSDName = Dictionary(uniqueKeysWithValues: media.map { ($0.bsdName, $0) })
        var includedBSDNames = Set([wholeMedia.bsdName])
        var pending = wholeMedia.childBSDNames

        if let containerBSDName = wholeMedia.apfsContainerBSDName {
            pending.append(containerBSDName)
        }

        while let bsdName = pending.popLast() {
            guard includedBSDNames.insert(bsdName).inserted else { continue }
            pending.append(contentsOf: recordsByBSDName[bsdName]?.childBSDNames ?? [])
        }

        let deviceNodes = Set(includedBSDNames.map { "/dev/\($0)" })
            .union(["/dev/r\(wholeMedia.bsdName)"])
        let mountURLs = Set(includedBSDNames.compactMap { recordsByBSDName[$0]?.mountURL })

        return OccupancyTargetScope(
            physicalBSDName: wholeMedia.bsdName,
            deviceNodes: deviceNodes,
            mountURLs: mountURLs
        )
    }
}
