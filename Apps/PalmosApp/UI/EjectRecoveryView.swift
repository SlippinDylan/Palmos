import AppKit
import Combine
import SwiftUI

import PalmosCore

struct EjectRecoveryView: View {
    let presentation: EjectRecoveryPresentation
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onRequestForce: () -> Void

    @State private var showsTechnicalDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(presentation.title)
                .font(.headline)

            Text(presentation.primaryText)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let guidance = presentation.guidance {
                Text(guidance)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let operationStatus = presentation.operationStatus {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(operationStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let detail = presentation.technicalDetail {
                DisclosureGroup(
                    String(localized: "eject.technicalDetails.label"),
                    isExpanded: $showsTechnicalDetail
                ) {
                    Text(detail)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                .font(.caption)
            }

            if presentation.actions.isEmpty == false {
                HStack(spacing: 8) {
                    recoveryButton(.cancel, action: onCancel)
                    recoveryButton(.retry, action: onRetry)
                        .disabled(presentation.isOperationActive)
                    recoveryButton(.requestForce, action: onRequestForce)
                        .disabled(presentation.isOperationActive)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func recoveryButton(
        _ action: EjectRecoveryAction,
        action handler: @escaping () -> Void
    ) -> some View {
        Button(EjectLocalization.actionTitle(for: action), action: handler)
            .accessibilityLabel(EjectLocalization.accessibilityLabel(for: action))
            .buttonStyle(.bordered)
            .controlSize(.small)
    }
}

@MainActor
final class EjectRecoveryWindowPresenter: NSObject, ObservableObject, NSWindowDelegate {
    private let coordinator: EjectCoordinator
    private var stateObservation: AnyCancellable?
    private var panel: NSPanel?
    private var isClosingProgrammatically = false

    init(coordinator: EjectCoordinator) {
        self.coordinator = coordinator
        super.init()
        stateObservation = coordinator.$state.sink { [weak self] state in
            self?.synchronize(with: state)
        }
    }

    func bringForwardIfVisible() {
        guard let panel else { return }
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func synchronize(with state: EjectWorkflowState) {
        guard shouldPresent(state) else {
            closePanel()
            return
        }
        if panel == nil { makePanel() }
        panel?.orderFrontRegardless()
    }

    private func shouldPresent(_ state: EjectWorkflowState) -> Bool {
        switch state {
        case .awaitingRecovery, .awaitingForceConfirmation, .failed, .resolutionFailed:
            return true
        case .working:
            return coordinator.retainedRecovery != nil
        default:
            return false
        }
    }

    private func makePanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 260),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = String(localized: "eject.recovery.windowTitle")
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.contentViewController = NSHostingController(rootView: EjectRecoveryWindowContent(
            coordinator: coordinator
        ))
        panel.center()
        self.panel = panel
    }

    private func closePanel() {
        guard let panel else { return }
        isClosingProgrammatically = true
        panel.close()
        isClosingProgrammatically = false
        self.panel = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isClosingProgrammatically == false { coordinator.cancel() }
        return true
    }
}

private struct EjectRecoveryWindowContent: View {
    @ObservedObject var coordinator: EjectCoordinator

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            Group {
                if case .awaitingForceConfirmation(let recovery) = coordinator.state {
                    forceConfirmation(recovery)
                } else if let presentation {
                    EjectRecoveryView(
                        presentation: presentation,
                        onCancel: coordinator.cancel,
                        onRetry: coordinator.retry,
                        onRequestForce: coordinator.requestForce
                    )
                }
            }
            .padding(18)
        }
        .frame(minWidth: 420, idealWidth: 440, maxWidth: 600, minHeight: 190, maxHeight: 520)
    }

    private var presentation: EjectRecoveryPresentation? {
        let deviceID = coordinator.retainedRecovery?.target.deviceID
            ?? coordinator.state.presentationDeviceID
        return EjectRecoveryPresentation(
            state: coordinator.state,
            retainedRecovery: coordinator.retainedRecovery,
            selectedDeviceID: deviceID
        )
    }

    private func forceConfirmation(_ recovery: EjectRecoveryState) -> some View {
        let presentation = EjectForceConfirmationPresentation(target: recovery.target)
        return VStack(alignment: .leading, spacing: 14) {
            Text(presentation.title)
                .font(.headline)
            Text(presentation.message)
                .foregroundStyle(.secondary)
            diagnosisSummary(recovery)
            HStack {
                Spacer()
                Button(EjectLocalization.actionTitle(for: .cancel)) {
                    coordinator.cancelForceConfirmation()
                }
                .keyboardShortcut(.defaultAction)
                Button(EjectLocalization.actionTitle(for: .confirmForce), role: .destructive) {
                    coordinator.confirmForce()
                }
            }
        }
    }

    @ViewBuilder
    private func diagnosisSummary(_ recovery: EjectRecoveryState) -> some View {
        switch recovery.diagnosis {
        case .pending:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(EjectLocalization.diagnosingOccupancy)
            }
            .foregroundStyle(.secondary)
        case .known(let holders):
            Text(EjectLocalization.knownHolderReason(
                ListFormatter.localizedString(byJoining: holders.map(\.preferredName))
            ))
            .foregroundStyle(.secondary)
        case .unknown:
            Text(EjectLocalization.unknownHolderReason)
                .foregroundStyle(.secondary)
        case .unavailable:
            Text(EjectLocalization.unavailableDiagnosisReason)
                .foregroundStyle(.secondary)
        }
    }
}

private extension EjectWorkflowState {
    var presentationDeviceID: DeviceID? {
        switch self {
        case .awaitingRecovery(let recovery), .awaitingForceConfirmation(let recovery):
            return recovery.target.deviceID
        case .working(let target, _):
            return target.deviceID
        case .failed(let target, _):
            return target.deviceID
        case .resolutionFailed(let request, _):
            return request.deviceID
        default:
            return nil
        }
    }
}
