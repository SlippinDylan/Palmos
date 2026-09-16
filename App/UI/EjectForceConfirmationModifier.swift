import SwiftUI

import PalmosCore

struct EjectForceConfirmationModifier: ViewModifier {
    let state: EjectWorkflowState
    let selectedDeviceID: DeviceID?
    let onCancel: () -> Void
    let onConfirm: () -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            presentation?.title ?? "",
            isPresented: isPresented,
            titleVisibility: .visible
        ) {
            Button(
                EjectLocalization.actionTitle(for: .cancel),
                role: .cancel,
                action: onCancel
            )
            .accessibilityLabel(EjectLocalization.accessibilityLabel(for: .cancel))

            Button(
                EjectLocalization.actionTitle(for: .confirmForce),
                role: .destructive,
                action: onConfirm
            )
            .accessibilityLabel(EjectLocalization.accessibilityLabel(for: .confirmForce))
        } message: {
            if let presentation {
                Text(presentation.message)
            }
        }
    }

    private var presentation: EjectForceConfirmationPresentation? {
        guard case .awaitingForceConfirmation(let recovery) = state else { return nil }
        guard recovery.target.deviceID == selectedDeviceID else { return nil }
        return .init(target: recovery.target)
    }

    private var isPresented: Binding<Bool> {
        Binding(
            get: { presentation != nil },
            set: { presented in
                if presented == false, presentation != nil {
                    onCancel()
                }
            }
        )
    }
}

extension View {
    func ejectForceConfirmation(
        state: EjectWorkflowState,
        selectedDeviceID: DeviceID?,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping () -> Void
    ) -> some View {
        modifier(EjectForceConfirmationModifier(
            state: state,
            selectedDeviceID: selectedDeviceID,
            onCancel: onCancel,
            onConfirm: onConfirm
        ))
    }
}
