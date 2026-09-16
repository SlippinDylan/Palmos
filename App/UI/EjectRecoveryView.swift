import AppKit
import Combine
import SwiftUI

import PalmosCore

struct EjectRecoveryView: View {
    let presentation: EjectRecoveryPresentation
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onRequestForce: () -> Void
    let onLayoutChange: () -> Void

    @State private var showsTechnicalDetail = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            warningIcon

            VStack(alignment: .leading, spacing: 10) {
                Text(presentation.title)
                    .font(.system(size: 15, weight: .bold))

                VStack(alignment: .leading, spacing: 4) {
                    Text(presentation.primaryText)
                    if let guidance = presentation.guidance {
                        Text(guidance)
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if let operationStatus = presentation.operationStatus {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text(operationStatus)
                            .font(.system(size: 12))
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
                    .onChange(of: showsTechnicalDetail) { _, _ in
                        onLayoutChange()
                    }
                }

                if presentation.actions.isEmpty == false {
                    actionRow
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var warningIcon: some View {
        Image(systemName: "externaldrive.badge.exclamationmark")
            .font(.system(size: 34, weight: .regular))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.yellow)
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 12)
            if presentation.actions.contains(.cancel) {
                recoveryButton(.cancel, action: onCancel)
                    .disabled(presentation.isOperationActive)
            }
            if presentation.actions.contains(.retry) {
                recoveryButton(.retry, action: onRetry)
                    .disabled(presentation.isOperationActive)
            }
            if presentation.actions.contains(.retryFailure) {
                recoveryButton(.retryFailure, action: onRetry)
                    .disabled(presentation.isOperationActive)
            }
            if presentation.actions.contains(.requestForce) {
                recoveryButton(.requestForce, action: onRequestForce)
                    .disabled(presentation.isOperationActive)
            }
        }
    }

    @ViewBuilder
    private func recoveryButton(
        _ action: EjectRecoveryAction,
        action handler: @escaping () -> Void
    ) -> some View {
        switch action {
        case .retry, .retryFailure:
            recoveryButtonLabel(action, handler: handler)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        case .requestForce, .confirmForce:
            Button(role: .destructive, action: handler) {
                Text(EjectLocalization.actionTitle(for: action))
            }
            .accessibilityLabel(EjectLocalization.accessibilityLabel(for: action))
            .buttonStyle(.bordered)
            .tint(.red)
        case .cancel:
            recoveryButtonLabel(action, handler: handler)
                .buttonStyle(.bordered)
        }
    }

    private func recoveryButtonLabel(
        _ action: EjectRecoveryAction,
        handler: @escaping () -> Void
    ) -> some View {
        Button(EjectLocalization.actionTitle(for: action), action: handler)
            .accessibilityLabel(EjectLocalization.accessibilityLabel(for: action))
    }
}

@MainActor
final class EjectRecoveryWindowPresenter: NSObject, ObservableObject, NSWindowDelegate {
    private let coordinator: EjectCoordinator
    private var terminalRetryHandler: @MainActor (EjectWorkflowRequest) -> Void = { _ in }
    private var stateObservation: AnyCancellable?
    private var panel: NSPanel?
    private var hostingController: NSHostingController<EjectRecoveryWindowContent>?
    private var isClosingProgrammatically = false
    private var suppressesPanelUntilWorkflowEnds = false

    private static let contentWidth: CGFloat = 480
    private static let minimumContentHeight: CGFloat = 150
    private static let maximumContentHeight: CGFloat = 560

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

    func setTerminalRetryHandler(
        _ handler: @escaping @MainActor (EjectWorkflowRequest) -> Void
    ) {
        terminalRetryHandler = handler
    }

    private func synchronize(with state: EjectWorkflowState) {
        if suppressesPanelUntilWorkflowEnds {
            guard isWorkflowInProgress(state) == false else {
                closePanel()
                return
            }
            suppressesPanelUntilWorkflowEnds = false
        }
        guard shouldPresent(state) else {
            closePanel()
            return
        }
        let isFirstPresentation = panel == nil
        if isFirstPresentation { makePanel() }
        if isFirstPresentation {
            NSApp.activate(ignoringOtherApps: true)
            panel?.makeKeyAndOrderFront(nil)
        } else {
            panel?.orderFrontRegardless()
        }
        scheduleResizeToFit()
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

    private func isWorkflowInProgress(_ state: EjectWorkflowState) -> Bool {
        switch state {
        case .preparing, .working, .awaitingRecovery, .awaitingForceConfirmation:
            true
        default:
            false
        }
    }

    private func makePanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: 220),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = ""
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .windowBackgroundColor
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentMinSize = NSSize(
            width: 460,
            height: Self.minimumContentHeight
        )
        panel.delegate = self

        let hostingController = NSHostingController(rootView: EjectRecoveryWindowContent(
            coordinator: coordinator,
            onRetryTerminal: { [weak self] request in
                self?.terminalRetryHandler(request)
            },
            onLayoutChange: { [weak self] in self?.scheduleResizeToFit() }
        ))
        panel.contentViewController = hostingController
        self.panel = panel
        self.hostingController = hostingController
        resizeToFit()
        panel.center()
    }

    private func closePanel() {
        guard let panel else { return }
        isClosingProgrammatically = true
        panel.close()
        isClosingProgrammatically = false
        self.panel = nil
        hostingController = nil
    }

    private func scheduleResizeToFit() {
        DispatchQueue.main.async { [weak self] in self?.resizeToFit() }
    }

    private func resizeToFit() {
        guard let panel, let hostingController else { return }
        let contentWidth = max(panel.contentRect(forFrameRect: panel.frame).width, Self.contentWidth)
        hostingController.view.frame.size.width = contentWidth
        hostingController.view.layoutSubtreeIfNeeded()

        let fittingHeight = ceil(hostingController.view.fittingSize.height)
        let contentHeight = min(
            max(fittingHeight, Self.minimumContentHeight),
            Self.maximumContentHeight
        )
        let contentSize = NSSize(width: contentWidth, height: contentHeight)
        let frameSize = panel.frameRect(
            forContentRect: NSRect(origin: .zero, size: contentSize)
        ).size
        guard abs(panel.frame.height - frameSize.height) > 1 else { return }

        var frame = panel.frame
        frame.origin.y = frame.maxY - frameSize.height
        frame.size = frameSize
        panel.setFrame(frame, display: true, animate: panel.isVisible)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingPanel = notification.object as? NSWindow,
              closingPanel === panel else { return }
        panel = nil
        hostingController = nil
        guard isClosingProgrammatically == false else { return }
        suppressesPanelUntilWorkflowEnds = true
        cancelOrDismissCurrentState()
    }

    private func cancelOrDismissCurrentState() {
        switch coordinator.state {
        case .failed, .resolutionFailed:
            coordinator.dismissTerminalFailure()
        case .working:
            break
        default:
            coordinator.cancel()
        }
    }
}

private struct EjectRecoveryWindowContent: View {
    @ObservedObject var coordinator: EjectCoordinator
    let onRetryTerminal: (EjectWorkflowRequest) -> Void
    let onLayoutChange: () -> Void

    var body: some View {
        ViewThatFits(in: .vertical) {
            dialogContent
                .fixedSize(horizontal: false, vertical: true)
            ScrollView(.vertical) {
                dialogContent
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var dialogContent: some View {
        Group {
            if case .awaitingForceConfirmation(let recovery) = coordinator.state {
                forceConfirmation(recovery)
            } else if let presentation {
                EjectRecoveryView(
                    presentation: presentation,
                    onCancel: cancel,
                    onRetry: retry,
                    onRequestForce: coordinator.requestForce,
                    onLayoutChange: onLayoutChange
                )
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 22)
        .frame(minWidth: 460, idealWidth: 480, maxWidth: .infinity, alignment: .topLeading)
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

    private func cancel() {
        switch coordinator.state {
        case .failed, .resolutionFailed:
            coordinator.dismissTerminalFailure()
        default:
            coordinator.cancel()
        }
    }

    private func retry() {
        guard case .failed(let target, _) = coordinator.state else {
            coordinator.retry()
            return
        }
        onRetryTerminal(EjectWorkflowRequest(
            deviceID: target.deviceID,
            displayName: target.displayName
        ))
    }

    private func forceConfirmation(_ recovery: EjectRecoveryState) -> some View {
        let presentation = EjectForceConfirmationPresentation(target: recovery.target)
        return HStack(alignment: .top, spacing: 16) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 34, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.yellow)
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 10) {
                Text(presentation.title)
                    .font(.system(size: 15, weight: .bold))
                Text(presentation.message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                diagnosisSummary(recovery)
                    .font(.system(size: 12))
                HStack(spacing: 8) {
                    Spacer(minLength: 12)
                    Button(EjectLocalization.actionTitle(for: .cancel)) {
                        coordinator.cancelForceConfirmation()
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.defaultAction)
                    Button(EjectLocalization.actionTitle(for: .confirmForce), role: .destructive) {
                        coordinator.confirmForce()
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
