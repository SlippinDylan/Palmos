import Foundation

import PalmosCore

enum EjectOperationStage: String, Codable, Equatable, Sendable {
    case preparing, unmounting, diagnosingOccupancy, awaitingRecoveryChoice
    case awaitingForceConfirmation, forceUnmounting, ejecting
    case ejectedSuccessfully, deviceDisappeared
}

enum EjectFailureCategory: String, Codable, Equatable, Sendable {
    case busy, exclusiveAccess, notFound, notMounted, notPermitted
    case notReady, io, timedOut, smartCompletionUnobservable, unknown
}

enum OccupancyType: String, Codable, CaseIterable, Equatable, Sendable {
    case openFileOrDirectory, workingDirectory, deviceNode, unknown
}

struct OccupancyHolder: Codable, Equatable, Hashable, Sendable {
    let pid: Int32
    let executableName: String
    let displayName: String?
    let type: OccupancyType

    var preferredName: String { displayName?.nilIfEmpty ?? executableName }
}

struct EjectFailure: Error, Equatable, Sendable {
    let stage: EjectOperationStage
    let category: EjectFailureCategory
    let rawStatus: Int32?
    let systemMessage: String?
    let physicalBSDName: String
    var holders: [OccupancyHolder]
}

/// The minimum identity needed to keep destructive disk operations attached to
/// the same physical medium after a BSD name is reused.
struct PhysicalDiskTargetIdentity: Equatable, Sendable {
    let bsdName: String
    let mediaRegistryEntryID: UInt64
}

/// Identifies a logical whole-disk object that must be unmounted before the
/// backing physical medium can be unmounted and ejected. APFS synthesized
/// containers have their own identity and are not children of the physical DA
/// whole disk, but they are never themselves sent to `DADiskEject`.
struct DiskArbitrationWholeDiskIdentity: Equatable, Sendable {
    let bsdName: String
    let mediaRegistryEntryID: UInt64
}

/// A freshly resolved plan for logical unmounts followed by physical eject.
struct DiskEjectOperationPlan: Equatable, Sendable {
    let physicalTarget: PhysicalDiskTargetIdentity
    let logicalWholeDiskTargets: [DiskArbitrationWholeDiskIdentity]

    init(
        physicalTarget: PhysicalDiskTargetIdentity,
        logicalWholeDiskTargets: [DiskArbitrationWholeDiskIdentity] = []
    ) {
        self.physicalTarget = physicalTarget
        self.logicalWholeDiskTargets = logicalWholeDiskTargets
    }
}

enum DiskEjectOutcome: Equatable, Sendable {
    case success
    case failure(EjectFailure)
    case targetInvalidated(stage: EjectOperationStage)

    static func success(_: Void) -> Self { .success }

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var failure: EjectFailure? {
        guard case .failure(let failure) = self else { return nil }
        return failure
    }
}

struct EjectWorkflowTarget: Equatable, Sendable {
    let deviceID: DeviceID
    let physicalBSDName: String
    let mediaRegistryEntryID: UInt64
    let displayName: String
    let topologyGeneration: Int

    var physicalIdentity: PhysicalDiskTargetIdentity {
        PhysicalDiskTargetIdentity(
            bsdName: physicalBSDName,
            mediaRegistryEntryID: mediaRegistryEntryID
        )
    }
}

struct EjectWorkflowRequest: Equatable, Sendable {
    let deviceID: DeviceID
    let displayName: String
}

struct OccupancyTargetScope: Equatable, Sendable {
    let physicalBSDName: String
    let deviceNodes: Set<String>
    let mountURLs: Set<URL>

    func contains(path: String) -> Bool {
        let candidateComponents = URL(fileURLWithPath: path).standardizedFileURL.pathComponents

        return mountURLs.contains { mountURL in
            let mountComponents = mountURL.standardizedFileURL.pathComponents
            return candidateComponents.starts(with: mountComponents)
        }
    }

    func contains(deviceNode: String) -> Bool {
        deviceNodes.contains(deviceNode)
    }
}

struct OccupancyScanResult: Equatable, Sendable {
    let holders: [OccupancyHolder]
    let isComplete: Bool
}

struct EjectRecoveryState: Equatable, Sendable {
    let target: EjectWorkflowTarget
    let failure: EjectFailure
    let holders: [OccupancyHolder]
}

enum EjectWorkflowState: Equatable, Sendable {
    case idle
    case preparing(EjectWorkflowRequest)
    case working(target: EjectWorkflowTarget, stage: EjectOperationStage)
    case awaitingRecovery(EjectRecoveryState)
    case awaitingForceConfirmation(EjectRecoveryState)
    case succeeded(EjectWorkflowTarget)
    case externallyUnmounted(EjectWorkflowTarget)
    case disappeared(EjectWorkflowTarget)
    case resolutionFailed(request: EjectWorkflowRequest, failure: EjectFailure)
    case failed(target: EjectWorkflowTarget, failure: EjectFailure)
}

protocol EjectBarrier: Sendable {
    func waitUntilReady() async throws
    func release() async
}

enum DeviceIOQuiescenceError: Error, Equatable, Sendable {
    case timedOut
    case cancelled
    case legacySMARTCompletionUnobservable
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
