import SwiftUI

import PalmosCore

enum FooterActionLabelLayout: Equatable {
    case horizontal
    case stacked
}

enum FooterActionBarMode: Equatable {
    case device
    case empty
}

struct FooterActionLayoutMetrics: Equatable {
    let labelLayout: FooterActionLabelLayout
    let controlSpacing: CGFloat
    let labelSpacing: CGFloat
    let iconFontSize: CGFloat
    let titleFontSize: CGFloat
    let minHeight: CGFloat
    let fixedWidth: CGFloat?

    static func forMode(_ mode: FooterActionBarMode) -> Self {
        switch mode {
        case .device:
            return Self(
                labelLayout: .stacked,
                controlSpacing: 6,
                labelSpacing: 4,
                iconFontSize: 12,
                titleFontSize: 10,
                minHeight: 46,
                fixedWidth: nil
            )
        case .empty:
            return Self(
                labelLayout: .horizontal,
                controlSpacing: 10,
                labelSpacing: 6,
                iconFontSize: 11,
                titleFontSize: 11,
                minHeight: 34,
                fixedWidth: 132
            )
        }
    }
}

struct ActionBarView: View {
    let actions: [SystemAction]
    let mode: FooterActionBarMode
    let isActionEnabled: (SystemAction) -> Bool
    let message: String?
    let onAction: (SystemAction) -> Void
    let onActivateEjectRecovery: () -> Void

    private var layoutMetrics: FooterActionLayoutMetrics {
        .forMode(mode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: layoutMetrics.controlSpacing) {
                if mode == .empty {
                    Spacer(minLength: 0)
                }

                ForEach(actions) { action in
                    Button {
                        onAction(action)
                        if action.kind == .eject { onActivateEjectRecovery() }
                    } label: {
                        FooterActionButtonLabel(
                            action: action,
                            metrics: layoutMetrics
                        )
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                    .buttonSizing(.flexible)
                    .frame(width: layoutMetrics.fixedWidth)
                    .disabled(isActionEnabled(action) == false)
                }

                if mode == .empty {
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity)
            .controlSize(.small)

            if let message, message.isEmpty == false {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }
}

private struct FooterActionButtonLabel: View {
    let action: SystemAction
    let metrics: FooterActionLayoutMetrics

    var body: some View {
        Group {
            switch metrics.labelLayout {
            case .horizontal:
                HStack(spacing: metrics.labelSpacing) {
                    icon
                    title
                }
            case .stacked:
                VStack(spacing: metrics.labelSpacing) {
                    icon
                    title
                }
            }
        }
        .frame(minHeight: metrics.minHeight)
    }

    private var icon: some View {
        Image(systemName: action.systemImageName)
            .font(.system(size: metrics.iconFontSize, weight: .semibold))
    }

    private var title: some View {
        Text(action.footerTitle)
            .font(.system(size: metrics.titleFontSize, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
    }
}
