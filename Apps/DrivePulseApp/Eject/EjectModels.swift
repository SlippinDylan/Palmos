import Foundation

import DrivePulseCore

enum EjectOperationStage: String, Codable, Equatable, Sendable {
    case preparing, unmounting, diagnosingOccupancy, awaitingRecoveryChoice
    case awaitingForceConfirmation, forceUnmounting, ejecting
    case ejectedSuccessfully, deviceDisappeared
}

enum EjectFailureCategory: String, Codable, Equatable, Sendable {
    case busy, exclusiveAccess, notFound, notMounted, notPermitted
    case notReady, io, timedOut, unknown
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

struct EjectWorkflowTarget: Equatable, Sendable {
    let deviceID: DeviceID
    let physicalBSDName: String
    let mediaRegistryEntryID: UInt64
    let displayName: String
    let topologyGeneration: Int
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
    case working(target: EjectWorkflowTarget, stage: EjectOperationStage)
    case awaitingRecovery(EjectRecoveryState)
    case awaitingForceConfirmation(EjectRecoveryState)
    case succeeded(EjectWorkflowTarget)
    case disappeared(EjectWorkflowTarget)
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
