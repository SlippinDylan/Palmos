import SwiftUI

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
                    recoveryButton(.requestForce, action: onRequestForce)
                }
                .disabled(presentation.isOperationActive)
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
