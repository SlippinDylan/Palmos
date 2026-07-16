import SwiftUI

import DrivePulseCore

struct MenuBarRootView: View {
    @ObservedObject var controller: DrivePulseAppController
    @ObservedObject var settingsWindowActivator: SettingsWindowActivator
    @ObservedObject private var ejectCoordinator: EjectCoordinator

    init(
        controller: DrivePulseAppController,
        settingsWindowActivator: SettingsWindowActivator
    ) {
        self.controller = controller
        self.settingsWindowActivator = settingsWindowActivator
        _ejectCoordinator = ObservedObject(wrappedValue: controller.ejectCoordinator)
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
            OverviewCardView(
                device: device,
                smartDetails: controller.selectedPanelSMARTDetails,
                settings: controller.settings
            )
            ThroughputCardView(device: device)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    HealthSMARTCardView(
                        helperPrompt: helperPrompt,
                        smartDetails: controller.selectedPanelSMARTDetails,
                        onInstallHelper: { controller.performSMARTPrimaryAction() },
                        onConfirmHelperInstall: { controller.installSMARTHelper() },
                        onDismissHelperPrompt: { controller.dismissSMARTPrompts() },
                        onRefresh: { controller.refreshSelectedDeviceSMART() }
                    )
                    TemperatureCardView(
                        smartDetails: controller.selectedPanelSMARTDetails,
                        settings: controller.settings
                    )
                    VolumesPartitionsCardView(device: device)
                    ConnectionNVMeCardView(device: device)
                    DeviceIdentityCardView(device: device)
                }
            }
        }
        .padding(14)
        .frame(height: contentAreaHeight)
    }

    private var contentAreaHeight: CGFloat {
        (NSScreen.main?.frame.height ?? 900) * 3 / 5
    }

    private var helperPrompt: SMARTHelperPrompt? {
        if controller.state.presentation.showHelperInstallPrompt {
            return .install
        }

        if controller.state.presentation.showHelperUpdatePrompt {
            return .update
        }

        return nil
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
