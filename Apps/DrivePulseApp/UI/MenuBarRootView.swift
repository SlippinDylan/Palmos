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

            DevicePickerView(
                devices: controller.state.devices,
                selectedDeviceID: Binding(
                    get: { controller.state.selectedDeviceID },
                    set: { controller.selectDevice($0) }
                )
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.regularMaterial)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                OverviewCardView(
                    device: controller.state.selectedDevice,
                    smartDetails: controller.state.selectedSMARTDetails,
                    settings: controller.settings
                )
                ThroughputCardView(device: controller.state.selectedDevice)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        HealthSMARTCardView(
                            helperPrompt: helperPrompt,
                            smartDetails: controller.state.selectedSMARTDetails,
                            onInstallHelper: { controller.performSMARTPrimaryAction() },
                            onConfirmHelperInstall: { controller.installSMARTHelper() },
                            onDismissHelperPrompt: { controller.dismissSMARTPrompts() },
                            onRefresh: { controller.refreshSelectedDeviceSMART() }
                        )
                        TemperatureCardView(
                            smartDetails: controller.state.selectedSMARTDetails,
                            settings: controller.settings
                        )
                        VolumesPartitionsCardView(device: controller.state.selectedDevice)
                        ConnectionNVMeCardView(device: controller.state.selectedDevice)
                        DeviceIdentityCardView(device: controller.state.selectedDevice)
                    }
                }
            }
            .padding(14)
            .frame(height: contentAreaHeight)

            Divider()

            ActionBarView(
                actions: controller.selectedFooterActions,
                isPerformingAction: controller.isPerformingSystemAction,
                message: controller.actionFeedback,
                ejectState: ejectCoordinator.state,
                retainedRecovery: ejectCoordinator.retainedRecovery,
                selectedDeviceID: controller.state.selectedDeviceID,
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
            selectedDeviceID: controller.state.selectedDeviceID,
            onCancel: controller.cancelForceConfirmation,
            onConfirm: controller.confirmForceEject
        )
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
