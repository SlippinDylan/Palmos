import Foundation
import SwiftUI

import DrivePulseCore

struct MenuBarVisualStyle {
    let usesLiquidGlass: Bool

    static func current(processInfo: ProcessInfo = .processInfo) -> Self {
        Self(
            usesLiquidGlass: supportsLiquidGlass(processInfo.operatingSystemVersion)
        )
    }

    static func supportsLiquidGlass(_ version: OperatingSystemVersion) -> Bool {
        version.majorVersion >= 26
    }
}

struct PanelControlCluster<Content: View>: View {
    let usesLiquidGlass: Bool
    let content: Content

    init(
        usesLiquidGlass: Bool,
        @ViewBuilder content: () -> Content
    ) {
        self.usesLiquidGlass = usesLiquidGlass
        self.content = content()
    }

    var body: some View {
        if #available(macOS 26.0, *), usesLiquidGlass {
            GlassEffectContainer(spacing: 10) {
                content
            }
        } else {
            content
        }
    }
}

struct PanelIconControlModifier<S: InsettableShape>: ViewModifier {
    let usesLiquidGlass: Bool
    let isEnabled: Bool
    let shape: S

    func body(content: Content) -> some View {
        content.modifier(
            PanelControlSurfaceModifier(
                usesLiquidGlass: usesLiquidGlass,
                isEnabled: isEnabled,
                isPressed: false,
                shape: shape
            )
        )
    }
}

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
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
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
                horizontalPadding: 8,
                verticalPadding: 8,
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
                horizontalPadding: 12,
                verticalPadding: 7,
                labelSpacing: 6,
                iconFontSize: 11,
                titleFontSize: 11,
                minHeight: 34,
                fixedWidth: 132
            )
        }
    }
}

private struct PanelFooterButtonStyle: ButtonStyle {
    let usesLiquidGlass: Bool
    let metrics: FooterActionLayoutMetrics
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .padding(.horizontal, metrics.horizontalPadding)
            .padding(.vertical, metrics.verticalPadding)
            .frame(maxWidth: .infinity, minHeight: metrics.minHeight)
            .contentShape(Capsule())
            .modifier(
                PanelControlSurfaceModifier(
                    usesLiquidGlass: usesLiquidGlass,
                    isEnabled: isEnabled,
                    isPressed: configuration.isPressed,
                    shape: Capsule()
                )
            )
    }
}

private struct PanelControlSurfaceModifier<S: InsettableShape>: ViewModifier {
    let usesLiquidGlass: Bool
    let isEnabled: Bool
    let isPressed: Bool
    let shape: S

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), usesLiquidGlass {
            content
                .opacity(isEnabled ? (isPressed ? 0.82 : 1) : 0.45)
                .glassEffect(.regular.interactive(isEnabled), in: shape)
                .scaleEffect(isPressed ? 0.98 : 1)
        } else {
            content
                .opacity(isEnabled ? (isPressed ? 0.88 : 1) : 0.45)
                .background(.regularMaterial, in: shape)
                .overlay {
                    shape.strokeBorder(Color.white.opacity(0.12))
                }
                .scaleEffect(isPressed ? 0.98 : 1)
        }
    }
}

struct ActionBarView: View {
    let actions: [SystemAction]
    let mode: FooterActionBarMode
    let isPerformingAction: Bool
    let message: String?
    let ejectState: EjectWorkflowState
    let retainedRecovery: EjectRecoveryState?
    let selectedDeviceID: DeviceID?
    let availableHeight: CGFloat
    let onAction: (SystemAction) -> Void
    let onCancelEject: () -> Void
    let onRetryEject: () -> Void
    let onRequestForceEject: () -> Void

    private var visualStyle: MenuBarVisualStyle {
        .current()
    }

    private var layoutMetrics: FooterActionLayoutMetrics {
        .forMode(mode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelControlCluster(usesLiquidGlass: visualStyle.usesLiquidGlass) {
                HStack(spacing: layoutMetrics.controlSpacing) {
                    if mode == .empty {
                        Spacer(minLength: 0)
                    }

                    ForEach(actions) { action in
                        Button {
                            onAction(action)
                        } label: {
                            FooterActionButtonLabel(
                                action: action,
                                metrics: layoutMetrics
                            )
                        }
                        .buttonStyle(
                            PanelFooterButtonStyle(
                                usesLiquidGlass: visualStyle.usesLiquidGlass,
                                metrics: layoutMetrics
                            )
                        )
                        .frame(width: layoutMetrics.fixedWidth)
                        .frame(
                            maxWidth: mode == .device
                                ? .infinity
                                : layoutMetrics.fixedWidth
                        )
                    }

                    if mode == .empty {
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            .disabled(isPerformingAction)

            if let message, message.isEmpty == false {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            if let presentation = EjectRecoveryPresentation(
                state: ejectState,
                retainedRecovery: retainedRecovery,
                selectedDeviceID: selectedDeviceID
            ) {
                ScrollView(.vertical, showsIndicators: true) {
                    EjectRecoveryView(
                        presentation: presentation,
                        onCancel: onCancelEject,
                        onRetry: onRetryEject,
                        onRequestForce: onRequestForceEject
                    )
                }
                .frame(maxHeight: recoveryViewMaximumHeight)
            }
        }
    }

    private var recoveryViewMaximumHeight: CGFloat {
        MenuBarPanelLayout.recoveryViewMaximumHeight(
            availableHeight: availableHeight,
            showsFeedback: message?.isEmpty == false
        )
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
        .frame(maxWidth: .infinity)
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
