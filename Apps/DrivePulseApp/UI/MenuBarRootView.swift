import SwiftUI

import DrivePulseCore
import MenuBarExtraAccess

enum MenuBarPanelLayout {
    static let fixedShellHeight: CGFloat = 195
    static let minimumFixedContentHeight: CGFloat = 455
    static let screenEdgeClearance: CGFloat = 12
    static let deviceContentVerticalInsets: CGFloat = 28
    static let deviceSectionSpacing: CGFloat = 12
    private static let recoveryViewHeightCap: CGFloat = 132
    private static let recoveryFooterSpacing: CGFloat = 8
    private static let feedbackFooterHeight: CGFloat = 25

    static func contentAreaHeight(
        availableHeight: CGFloat,
        showsFeedback: Bool = false,
        showsRecovery: Bool = false
    ) -> CGFloat {
        let footerSupplement = footerSupplementHeight(
            availableHeight: availableHeight,
            showsFeedback: showsFeedback,
            showsRecovery: showsRecovery
        )
        return max(
            usablePanelHeight(availableHeight: availableHeight)
                - fixedShellHeight
                - footerSupplement,
            0
        )
    }

    static func usablePanelHeight(availableHeight: CGFloat) -> CGFloat {
        max(availableHeight - screenEdgeClearance, 0)
    }

    static func footerSupplementHeight(
        availableHeight: CGFloat,
        showsFeedback: Bool,
        showsRecovery: Bool
    ) -> CGFloat {
        (showsFeedback ? feedbackFooterHeight : 0)
            + (showsRecovery
                ? recoveryViewMaximumHeight(
                    availableHeight: availableHeight,
                    showsFeedback: showsFeedback
                ) + recoveryFooterSpacing
                : 0)
    }

    static func recoveryViewMaximumHeight(
        availableHeight: CGFloat,
        showsFeedback: Bool
    ) -> CGFloat {
        let feedbackHeight = showsFeedback ? feedbackFooterHeight : 0
        let availableRecoveryHeight = usablePanelHeight(availableHeight: availableHeight)
            - fixedShellHeight
            - minimumFixedContentHeight
            - recoveryFooterSpacing
            - feedbackHeight
        return min(max(availableRecoveryHeight, 0), recoveryViewHeightCap)
    }

    static func detailsViewportHeight(
        maximumContentAreaHeight: CGFloat,
        fixedDetailsHeight: CGFloat,
        detailsContentHeight: CGFloat
    ) -> CGFloat {
        guard detailsContentHeight > 0 else { return 0 }
        let availableHeight = maximumContentAreaHeight
            - deviceContentVerticalInsets
            - fixedDetailsHeight
            - deviceSectionSpacing
        return min(detailsContentHeight, max(availableHeight, 0))
    }

    static func resolvedContentAreaHeight(
        maximumContentAreaHeight: CGFloat,
        fixedDetailsHeight: CGFloat,
        detailsContentHeight: CGFloat
    ) -> CGFloat {
        let detailsSpacing = detailsContentHeight > 0 ? deviceSectionSpacing : 0
        let viewportHeight = detailsViewportHeight(
            maximumContentAreaHeight: maximumContentAreaHeight,
            fixedDetailsHeight: fixedDetailsHeight,
            detailsContentHeight: detailsContentHeight
        )
        return min(
            maximumContentAreaHeight,
            deviceContentVerticalInsets
                + fixedDetailsHeight
                + detailsSpacing
                + viewportHeight
        )
    }
}

struct MenuBarRootView: View {
    @ObservedObject var controller: DrivePulseAppController
    @ObservedObject var settingsWindowActivator: SettingsWindowActivator
    @ObservedObject private var ejectCoordinator: EjectCoordinator
    @ObservedObject private var settings: AppSettings
    @State private var availableScreenHeight: CGFloat = 900
    @State private var fixedDetailsHeight: CGFloat = 0
    @State private var configurableDetailsHeight: CGFloat = 0

    init(
        controller: DrivePulseAppController,
        settingsWindowActivator: SettingsWindowActivator
    ) {
        self.controller = controller
        self.settingsWindowActivator = settingsWindowActivator
        _ejectCoordinator = ObservedObject(wrappedValue: controller.ejectCoordinator)
        _settings = ObservedObject(wrappedValue: controller.settings)
    }

    var body: some View {
        VStack(spacing: 0) {
            MenuBarHeaderView(controller: controller, settingsWindowActivator: settingsWindowActivator)

            Divider()

            panelContent

            Divider()

            ActionBarView(
                actions: controller.selectedFooterActions,
                mode: controller.selectedPanelDevice == nil ? .empty : .device,
                isPerformingAction: controller.isPerformingSystemAction,
                message: controller.actionFeedback,
                ejectState: ejectCoordinator.state,
                retainedRecovery: ejectCoordinator.retainedRecovery,
                selectedDeviceID: controller.selectedPanelDeviceID,
                availableHeight: availableScreenHeight,
                onAction: controller.perform,
                onCancelEject: controller.cancelEject,
                onRetryEject: controller.retryEject,
                onRequestForceEject: controller.requestForceEject
            )
            .padding(14)
            .background(.regularMaterial)
        }
        .frame(width: 360)
        .containerBackground(.regularMaterial, for: .window)
        .introspectMenuBarExtraWindow { window in
            updateAvailableScreenHeight(from: window)
        }
        .ejectForceConfirmation(
            state: ejectCoordinator.state,
            selectedDeviceID: controller.selectedPanelDeviceID,
            onCancel: controller.cancelForceConfirmation,
            onConfirm: controller.confirmForceEject
        )
    }

    @ViewBuilder
    private var panelContent: some View {
        if let device = controller.selectedPanelDevice {
            mountedDeviceContent(device)
        } else {
            NoMountedDeviceView()
                .frame(height: 280)
        }
    }

    private func mountedDeviceContent(_ device: ExternalDevice) -> some View {
        VStack(spacing: 0) {
            DevicePickerView(
                devices: controller.panelDevices,
                selectedDeviceID: Binding(
                    get: { controller.selectedPanelDeviceID },
                    set: { controller.selectDevice($0) }
                )
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.regularMaterial)

            Divider()

            deviceDetails(device)
        }
    }

    private func deviceDetails(_ device: ExternalDevice) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                OverviewCardView(
                    device: device,
                    smartDetails: controller.selectedPanelSMARTDetails,
                    settings: settings
                )
                ThroughputCardView(device: device)
                CapacityUsageCardView(device: device)
            }
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: FixedDetailsHeightPreferenceKey.self,
                        value: proxy.size.height
                    )
                }
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    configurableDetails(device)
                }
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: ConfigurableDetailsHeightPreferenceKey.self,
                            value: proxy.size.height
                        )
                    }
                }
            }
            .frame(height: detailsViewportHeight)
        }
        .padding(14)
        .frame(height: resolvedContentAreaHeight)
        .onPreferenceChange(FixedDetailsHeightPreferenceKey.self) {
            guard $0 >= 0, abs(fixedDetailsHeight - $0) > 0.5 else { return }
            fixedDetailsHeight = $0
        }
        .onPreferenceChange(ConfigurableDetailsHeightPreferenceKey.self) {
            guard $0 >= 0, abs(configurableDetailsHeight - $0) > 0.5 else { return }
            configurableDetailsHeight = $0
        }
    }

    private var maximumContentAreaHeight: CGFloat {
        MenuBarPanelLayout.contentAreaHeight(
            availableHeight: availableScreenHeight,
            showsFeedback: hasActionFeedback,
            showsRecovery: hasEjectRecovery
        )
    }

    private var measuredFixedDetailsHeight: CGFloat {
        fixedDetailsHeight > 0
            ? fixedDetailsHeight
            : max(MenuBarPanelLayout.minimumFixedContentHeight - 28, 0)
    }

    private var detailsViewportHeight: CGFloat {
        MenuBarPanelLayout.detailsViewportHeight(
            maximumContentAreaHeight: maximumContentAreaHeight,
            fixedDetailsHeight: measuredFixedDetailsHeight,
            detailsContentHeight: configurableDetailsHeight
        )
    }

    private var resolvedContentAreaHeight: CGFloat {
        MenuBarPanelLayout.resolvedContentAreaHeight(
            maximumContentAreaHeight: maximumContentAreaHeight,
            fixedDetailsHeight: measuredFixedDetailsHeight,
            detailsContentHeight: configurableDetailsHeight
        )
    }

    private var hasActionFeedback: Bool {
        controller.actionFeedback?.isEmpty == false
    }

    private var hasEjectRecovery: Bool {
        EjectRecoveryPresentation(
            state: ejectCoordinator.state,
            retainedRecovery: ejectCoordinator.retainedRecovery,
            selectedDeviceID: controller.selectedPanelDeviceID
        ) != nil
    }

    @ViewBuilder
    private func configurableDetails(_ device: ExternalDevice) -> some View {
        if showsHelperDependentSection && helperRequirement != nil {
            SMARTHelperPlaceholderView(
                requiresUpdate: helperRequirement == .updateHelper,
                onOpenSettings: openSettings
            )
        } else {
            if settings[isVisible: .healthSMART] {
                HealthSMARTCardView(
                    smartDetails: controller.selectedPanelSMARTDetails,
                    onRefresh: { controller.refreshSelectedDeviceSMART() }
                )
            }

            if settings[isVisible: .temperature] {
                TemperatureCardView(
                    smartDetails: controller.selectedPanelSMARTDetails,
                    settings: settings
                )
            }
        }

        if settings[isVisible: .volumesPartitions] {
            VolumesPartitionsCardView(device: device)
        }

        if settings[isVisible: .connectionNVMe] {
            ConnectionNVMeCardView(device: device)
        }

        if settings[isVisible: .deviceIdentity] {
            DeviceIdentityCardView(device: device)
        }
    }

    private var showsHelperDependentSection: Bool {
        settings[isVisible: .healthSMART] || settings[isVisible: .temperature]
    }

    private var helperRequirement: SMARTPresentationPrimaryAction? {
        switch controller.selectedPanelSMARTDetails?.snapshot {
        case .helperNotInstalled:
            return .installHelper
        case .updateRequired:
            return .updateHelper
        default:
            return nil
        }
    }

    private func openSettings() {
        controller.isMenuBarPanelPresented = false
        settingsWindowActivator.open()
    }

    private func updateAvailableScreenHeight(from window: NSWindow) {
        guard let visibleHeight = window.screen?.visibleFrame.height,
              visibleHeight > 0,
              abs(availableScreenHeight - visibleHeight) > 0.5 else {
            return
        }
        availableScreenHeight = visibleHeight
    }
}

private struct FixedDetailsHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ConfigurableDetailsHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct NoMountedDeviceView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.plus")
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text("No Mounted External Drives")
                .font(.headline)

            Text("Connect and mount an external drive to start monitoring.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MenuBarHeaderView: View {
    @ObservedObject var controller: DrivePulseAppController
    @ObservedObject var settingsWindowActivator: SettingsWindowActivator

    private var visualStyle: MenuBarVisualStyle {
        .current()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("DrivePulse")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)

            Spacer(minLength: 0)

            PanelControlCluster(usesLiquidGlass: visualStyle.usesLiquidGlass) {
                Button {
                    controller.isMenuBarPanelPresented = false
                    settingsWindowActivator.open()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .modifier(
                            PanelIconControlModifier(
                                usesLiquidGlass: visualStyle.usesLiquidGlass,
                                isEnabled: true,
                                shape: Circle()
                            )
                        )
                }
                .buttonStyle(.plain)
                .help("Settings")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }
}
