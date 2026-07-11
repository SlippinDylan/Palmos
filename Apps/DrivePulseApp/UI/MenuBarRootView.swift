import SwiftUI

import DrivePulseCore

struct MenuBarRootView: View {
    @ObservedObject var controller: DrivePulseAppController
    @ObservedObject var settingsWindowActivator: SettingsWindowActivator

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
                            smartDetails: controller.state.selectedSMARTDetails,
                            onInstallHelper: { controller.performSMARTPrimaryAction() },
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
                onAction: controller.perform
            )
            .padding(14)
            .background(.regularMaterial)
        }
        .frame(width: 360)
        .containerBackground(.regularMaterial, for: .window)
        .alert(
            "Install Advanced Monitoring",
            isPresented: installPromptBinding
        ) {
            Button("Install") {
                controller.installSMARTHelper()
            }
            Button("Cancel", role: .cancel) {
                controller.dismissSMARTPrompts()
            }
        } message: {
            Text("DrivePulse needs to install the privileged SMART helper to read drive health data.")
        }
        .alert(
            "Update Advanced Monitoring",
            isPresented: updatePromptBinding
        ) {
            Button("Update") {
                controller.installSMARTHelper()
            }
            Button("Cancel", role: .cancel) {
                controller.dismissSMARTPrompts()
            }
        } message: {
            Text("DrivePulse needs to update the privileged SMART helper before SMART data can be refreshed.")
        }
    }

    private var contentAreaHeight: CGFloat {
        (NSScreen.main?.frame.height ?? 900) * 3 / 5
    }

    private var installPromptBinding: Binding<Bool> {
        Binding(
            get: { controller.state.presentation.showHelperInstallPrompt },
            set: { isPresented in
                if isPresented == false {
                    controller.dismissSMARTPrompts()
                }
            }
        )
    }

    private var updatePromptBinding: Binding<Bool> {
        Binding(
            get: { controller.state.presentation.showHelperUpdatePrompt },
            set: { isPresented in
                if isPresented == false {
                    controller.dismissSMARTPrompts()
                }
            }
        )
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
