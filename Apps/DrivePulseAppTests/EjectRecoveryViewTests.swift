import SwiftUI
import XCTest

import DrivePulseCore

@testable import DrivePulseApp

final class EjectRecoveryViewTests: XCTestCase {
    func testInitialPreparationRendersVisibleProgressForSelectedDevice() {
        let request = EjectWorkflowRequest(
            deviceID: target.deviceID,
            displayName: target.displayName
        )

        let presentation = EjectRecoveryPresentation(
            state: .preparing(request),
            selectedDeviceID: target.deviceID
        )

        XCTAssertEqual(presentation?.operationStatus, EjectLocalization.operationInProgress)
        XCTAssertTrue(presentation?.isOperationActive == true)
        XCTAssertEqual(presentation?.actions, [])
    }

    func testInitialResolutionFailureRendersLocalizedReason() {
        let request = EjectWorkflowRequest(
            deviceID: target.deviceID,
            displayName: target.displayName
        )
        let failure = EjectFailure(
            stage: .preparing,
            category: .notFound,
            rawStatus: nil,
            systemMessage: nil,
            physicalBSDName: "",
            holders: []
        )

        let presentation = EjectRecoveryPresentation(
            state: .resolutionFailed(request: request, failure: failure),
            selectedDeviceID: target.deviceID
        )

        XCTAssertTrue(presentation?.title.contains(target.displayName) == true)
        XCTAssertFalse(presentation?.reason.isEmpty == true)
        XCTAssertEqual(presentation?.primaryText, presentation?.reason)
        XCTAssertEqual(presentation?.actions, [])
    }

    func testKnownHoldersUsePreferredNamesAndLocalizedListFormatting() {
        let presentation = EjectRecoveryPresentation(
            state: .awaitingRecovery(recovery(holders: [
                .init(pid: 2, executableName: "zsh", displayName: "Terminal", type: .workingDirectory),
                .init(pid: 1, executableName: "Finder", displayName: nil, type: .openFileOrDirectory)
            ])),
            selectedDeviceID: target.deviceID
        )

        let names = ["Terminal", "Finder"]
        XCTAssertNotNil(presentation)
        XCTAssertTrue(presentation?.reason.contains(ListFormatter.localizedString(byJoining: names)) == true)
        XCTAssertEqual(presentation?.actions, [.cancel, .retry, .requestForce])
    }

    func testUnknownHolderCopyIsHonest() {
        let presentation = EjectRecoveryPresentation(
            state: .awaitingRecovery(recovery()),
            selectedDeviceID: target.deviceID
        )

        XCTAssertEqual(presentation?.reason, EjectLocalization.unknownHolderReason)
        XCTAssertTrue(presentation?.reason.contains("macOS") == true)
        XCTAssertTrue(presentation?.reason.contains("DrivePulse") == true)
    }

    func testRecoveryOnlyRendersForCapturedSelectedDevice() {
        XCTAssertNotNil(EjectRecoveryPresentation(
            state: .awaitingRecovery(recovery()),
            selectedDeviceID: target.deviceID
        ))
        XCTAssertNil(EjectRecoveryPresentation(
            state: .awaitingRecovery(recovery()),
            selectedDeviceID: DeviceID(rawValue: "other")
        ))
    }

    func testWorkingRetryKeepsRecoveryContextVisibleAndDisablesActions() {
        let recovery = recovery(holders: [
            .init(pid: 42, executableName: "Finder", displayName: nil, type: .openFileOrDirectory)
        ])
        let presentation = EjectRecoveryPresentation(
            state: .working(target: target, stage: .unmounting),
            retainedRecovery: recovery,
            selectedDeviceID: target.deviceID
        )

        XCTAssertEqual(presentation?.reason, EjectLocalization.knownHolderReason("Finder"))
        XCTAssertEqual(presentation?.actions, [.cancel, .retry, .requestForce])
        XCTAssertTrue(presentation?.isOperationActive == true)
        XCTAssertEqual(presentation?.operationStatus, EjectLocalization.operationInProgress)
    }

    func testWorkingWithoutRetainedRecoveryDoesNotRenderRecoveryUI() {
        XCTAssertNil(EjectRecoveryPresentation(
            state: .working(target: target, stage: .unmounting),
            retainedRecovery: nil,
            selectedDeviceID: target.deviceID
        ))
    }

    func testForceRequestIsOnlyAConfirmationIntent() {
        let presentation = EjectRecoveryPresentation(
            state: .awaitingRecovery(recovery()),
            selectedDeviceID: target.deviceID
        )

        XCTAssertEqual(presentation?.actions.last, .requestForce)
        XCTAssertFalse(presentation?.actions.contains(.confirmForce) == true)
    }

    func testForceConfirmationOrdersSafeCancelBeforeDestructiveAction() {
        let presentation = EjectForceConfirmationPresentation(target: target)

        XCTAssertEqual(presentation.actions, [
            .init(kind: .cancel, role: .cancel),
            .init(kind: .confirmForce, role: .destructive)
        ])
    }

    func testNonBusyFailureHasNoForceAndIncludesStageAwareTechnicalDetail() {
        let failure = EjectFailure(
            stage: .ejecting,
            category: .io,
            rawStatus: Int32(bitPattern: 0xFEDC_BA98),
            systemMessage: "I/O error",
            physicalBSDName: "disk4",
            holders: []
        )
        let presentation = EjectRecoveryPresentation(
            state: .failed(target: target, failure: failure),
            selectedDeviceID: target.deviceID
        )

        XCTAssertEqual(presentation?.actions, [])
        XCTAssertFalse(presentation?.primaryText.isEmpty == true)
        XCTAssertNotEqual(presentation?.primaryText, failure.systemMessage)
        XCTAssertTrue(presentation?.technicalDetail?.contains("0xFEDCBA98") == true)
    }

    func testUnobservableSMARTCompletionExplainsRestartRecovery() {
        let failure = EjectFailure(
            stage: .preparing,
            category: .smartCompletionUnobservable,
            rawStatus: nil,
            systemMessage: nil,
            physicalBSDName: "disk4",
            holders: []
        )
        let presentation = EjectRecoveryPresentation(
            state: .failed(target: target, failure: failure),
            selectedDeviceID: target.deviceID
        )

        XCTAssertEqual(presentation?.reason, EjectLocalization.smartCompletionUnobservableReason)
        XCTAssertEqual(presentation?.guidance, EjectLocalization.smartCompletionUnobservableGuidance)
        XCTAssertEqual(presentation?.actions, [])
    }

    func testAccessibilityLabelsDistinguishRetryAndForceInSafeOrder() {
        let presentation = EjectRecoveryPresentation(
            state: .awaitingRecovery(recovery()),
            selectedDeviceID: target.deviceID
        )

        XCTAssertEqual(presentation?.actions, [.cancel, .retry, .requestForce])
        XCTAssertNotEqual(
            EjectLocalization.accessibilityLabel(for: .retry),
            EjectLocalization.accessibilityLabel(for: .requestForce)
        )
    }

    func testSuccessAndDisappearanceUseDistinctFeedback() {
        XCTAssertNotEqual(
            EjectLocalization.successFeedback(target: target),
            EjectLocalization.disappearanceFeedback(target: target)
        )
        XCTAssertTrue(EjectLocalization.successFeedback(target: target).contains(target.displayName))
        XCTAssertTrue(EjectLocalization.disappearanceFeedback(target: target).contains(target.displayName))
    }

    private let target = EjectWorkflowTarget(
        deviceID: DeviceID(rawValue: "serial:abc"),
        physicalBSDName: "disk4",
        mediaRegistryEntryID: 4_001,
        displayName: "Samsung T7",
        topologyGeneration: 9
    )

    private func recovery(holders: [OccupancyHolder] = []) -> EjectRecoveryState {
        .init(
            target: target,
            failure: .init(
                stage: .unmounting,
                category: .busy,
                rawStatus: Int32(bitPattern: 0x0000_C010),
                systemMessage: nil,
                physicalBSDName: "disk4",
                holders: holders
            ),
            holders: holders
        )
    }
}
