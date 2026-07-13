import Foundation
import SwiftUI

import DrivePulseCore

enum EjectRecoveryAction: Equatable, Sendable {
    case cancel
    case retry
    case requestForce
    case confirmForce
}

enum EjectConfirmationRole: Equatable, Sendable {
    case cancel
    case destructive
}

struct EjectConfirmationAction: Equatable, Sendable {
    let kind: EjectRecoveryAction
    let role: EjectConfirmationRole
}

struct EjectForceConfirmationPresentation: Equatable, Sendable {
    let title: String
    let message: String
    let actions: [EjectConfirmationAction]

    init(target: EjectWorkflowTarget) {
        title = EjectLocalization.forceConfirmationTitle(target: target)
        message = EjectLocalization.forceConfirmationMessage
        actions = [
            .init(kind: .cancel, role: .cancel),
            .init(kind: .confirmForce, role: .destructive)
        ]
    }
}

struct EjectRecoveryPresentation: Equatable, Sendable {
    let target: EjectWorkflowTarget
    let title: String
    let primaryText: String
    let reason: String
    let guidance: String?
    let technicalDetail: String?
    let actions: [EjectRecoveryAction]
    let isOperationActive: Bool

    private init(
        target: EjectWorkflowTarget,
        title: String,
        primaryText: String,
        reason: String,
        guidance: String?,
        technicalDetail: String?,
        actions: [EjectRecoveryAction],
        isOperationActive: Bool
    ) {
        self.target = target
        self.title = title
        self.primaryText = primaryText
        self.reason = reason
        self.guidance = guidance
        self.technicalDetail = technicalDetail
        self.actions = actions
        self.isOperationActive = isOperationActive
    }

    init?(state: EjectWorkflowState, selectedDeviceID: DeviceID?) {
        switch state {
        case .awaitingRecovery(let recovery):
            guard recovery.target.deviceID == selectedDeviceID else { return nil }
            self = Self.recovery(recovery, isOperationActive: false)
        case .awaitingForceConfirmation(let recovery):
            guard recovery.target.deviceID == selectedDeviceID else { return nil }
            self = Self.recovery(recovery, isOperationActive: true)
        case .failed(let target, let failure):
            guard target.deviceID == selectedDeviceID else { return nil }
            self.init(
                target: target,
                title: EjectLocalization.failureTitle(target: target),
                primaryText: EjectLocalization.failurePrimaryText(failure),
                reason: EjectLocalization.failureReason(failure),
                guidance: nil,
                technicalDetail: EjectLocalization.technicalDetail(failure),
                actions: [],
                isOperationActive: false
            )
        default:
            return nil
        }
    }

    private static func recovery(
        _ recovery: EjectRecoveryState,
        isOperationActive: Bool
    ) -> Self {
        let holders = recovery.holders.map(\.preferredName)
        let reason = holders.isEmpty
            ? EjectLocalization.unknownHolderReason
            : EjectLocalization.knownHolderReason(
                ListFormatter.localizedString(byJoining: holders)
            )
        return Self(
            target: recovery.target,
            title: EjectLocalization.failureTitle(target: recovery.target),
            primaryText: reason,
            reason: reason,
            guidance: EjectLocalization.recoveryGuidance,
            technicalDetail: EjectLocalization.technicalDetail(recovery.failure),
            actions: [.cancel, .retry, .requestForce],
            isOperationActive: isOperationActive
        )
    }
}

enum EjectLocalization {
    static func failureTitle(target: EjectWorkflowTarget) -> String {
        format(String(localized: "eject.recovery.title"), target.displayName)
    }

    static func knownHolderReason(_ names: String) -> String {
        format(String(localized: "eject.recovery.knownHolders"), names)
    }

    static var unknownHolderReason: String {
        String(localized: "eject.recovery.unknownHolder")
    }

    static var recoveryGuidance: String {
        String(localized: "eject.recovery.guidance")
    }

    static func actionTitle(for action: EjectRecoveryAction) -> String {
        switch action {
        case .cancel: String(localized: "eject.action.cancel")
        case .retry: String(localized: "eject.action.retry")
        case .requestForce: String(localized: "eject.action.requestForce")
        case .confirmForce: String(localized: "eject.action.confirmForce")
        }
    }

    static func accessibilityLabel(for action: EjectRecoveryAction) -> String {
        switch action {
        case .cancel: String(localized: "eject.accessibility.cancel")
        case .retry: String(localized: "eject.accessibility.retry")
        case .requestForce: String(localized: "eject.accessibility.requestForce")
        case .confirmForce: String(localized: "eject.accessibility.confirmForce")
        }
    }

    static func forceConfirmationTitle(target: EjectWorkflowTarget) -> String {
        format(String(localized: "eject.forceConfirmation.title"), target.displayName)
    }

    static var forceConfirmationMessage: String {
        String(localized: "eject.forceConfirmation.message")
    }

    static func successFeedback(target: EjectWorkflowTarget) -> String {
        format(String(localized: "eject.result.safeToRemove"), target.displayName)
    }

    static func disappearanceFeedback(target: EjectWorkflowTarget) -> String {
        format(String(localized: "eject.result.deviceDisappeared"), target.displayName)
    }

    static func failurePrimaryText(_ failure: EjectFailure) -> String {
        format(
            String(localized: "eject.error.message"),
            stageName(failure.stage),
            categoryName(failure.category)
        )
    }

    static func failureReason(_ failure: EjectFailure) -> String {
        failure.systemMessage?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? categoryName(failure.category)
    }

    static func technicalDetail(_ failure: EjectFailure) -> String? {
        guard let rawStatus = failure.rawStatus else { return nil }
        return format(
            String(localized: "eject.error.technicalDetail"),
            UInt32(bitPattern: rawStatus),
            failure.physicalBSDName
        )
    }

    static func occupancyDescription(_ type: OccupancyType) -> String {
        switch type {
        case .openFileOrDirectory: String(localized: "eject.occupancy.openFileOrDirectory")
        case .workingDirectory: String(localized: "eject.occupancy.workingDirectory")
        case .deviceNode: String(localized: "eject.occupancy.deviceNode")
        case .unknown: String(localized: "eject.occupancy.unknown")
        }
    }

    private static func stageName(_ stage: EjectOperationStage) -> String {
        switch stage {
        case .preparing: String(localized: "eject.stage.preparing")
        case .unmounting: String(localized: "eject.stage.unmounting")
        case .diagnosingOccupancy: String(localized: "eject.stage.diagnosingOccupancy")
        case .awaitingRecoveryChoice: String(localized: "eject.stage.awaitingRecoveryChoice")
        case .awaitingForceConfirmation: String(localized: "eject.stage.awaitingForceConfirmation")
        case .forceUnmounting: String(localized: "eject.stage.forceUnmounting")
        case .ejecting: String(localized: "eject.stage.ejecting")
        case .ejectedSuccessfully: String(localized: "eject.stage.ejectedSuccessfully")
        case .deviceDisappeared: String(localized: "eject.stage.deviceDisappeared")
        }
    }

    private static func categoryName(_ category: EjectFailureCategory) -> String {
        switch category {
        case .busy: String(localized: "eject.error.busy")
        case .exclusiveAccess: String(localized: "eject.error.exclusiveAccess")
        case .notFound: String(localized: "eject.error.notFound")
        case .notMounted: String(localized: "eject.error.notMounted")
        case .notPermitted: String(localized: "eject.error.notPermitted")
        case .notReady: String(localized: "eject.error.notReady")
        case .io: String(localized: "eject.error.io")
        case .timedOut: String(localized: "eject.error.timedOut")
        case .unknown: String(localized: "eject.error.unknown")
        }
    }

    private static func format(_ format: String, _ arguments: CVarArg...) -> String {
        String(format: format, locale: .current, arguments: arguments)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
