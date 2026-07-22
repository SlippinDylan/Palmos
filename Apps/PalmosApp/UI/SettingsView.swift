import SwiftUI

import PalmosCore

struct SettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var settings: AppSettings
    @ObservedObject var launchAtLoginController: LaunchAtLoginController
    @ObservedObject var smartHelperManager: SMARTHelperManager
    let onInstallOrUpdateHelper: () -> Void
    let onRefreshHelperStatus: () -> Void

    var body: some View {
        TabView {
            GeneralSettingsPane(
                settings: settings,
                launchAtLoginController: launchAtLoginController,
                smartHelperManager: smartHelperManager,
                onInstallOrUpdateHelper: onInstallOrUpdateHelper,
                onRefreshHelperStatus: onRefreshHelperStatus
            )
            .tabItem { Label("General", systemImage: "gearshape") }

            DisplaySettingsPane(settings: settings)
                .tabItem { Label("Display", systemImage: "rectangle.3.group") }

            AboutSettingsPane()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding(20)
        .frame(width: 520, height: 390)
        .onAppear(perform: refreshExternalState)
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            refreshExternalState()
        }
    }

    private func refreshExternalState() {
        launchAtLoginController.refreshStatus()
        onRefreshHelperStatus()
    }
}

private struct GeneralSettingsPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var launchAtLoginController: LaunchAtLoginController
    @ObservedObject var smartHelperManager: SMARTHelperManager
    let onInstallOrUpdateHelper: () -> Void
    let onRefreshHelperStatus: () -> Void

    var body: some View {
        SettingsPane(
            title: "General",
            subtitle: "Choose how Palmos behaves on this Mac."
        ) {
            SettingsCard {
                SettingsControlRow(
                    title: "Temperature Unit",
                    systemImage: "thermometer.medium"
                ) {
                    Picker("Temperature Unit", selection: $settings.temperatureUnit) {
                        Text("Celsius").tag(TemperatureUnit.celsius)
                        Text("Fahrenheit").tag(TemperatureUnit.fahrenheit)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }

                Divider()

                SettingsControlRow(
                    title: "Launch at Login",
                    subtitle: "Palmos can launch automatically when you sign in.",
                    systemImage: "power"
                ) {
                    Toggle(
                        "Launch at Login",
                        isOn: Binding(
                            get: { launchAtLoginController.isEnabled },
                            set: { launchAtLoginController.setEnabled($0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(launchAtLoginController.isUpdating)
                }

                launchAtLoginMessages
            }

            SMARTHelperSettingsSection(
                manager: smartHelperManager,
                onInstallOrUpdate: onInstallOrUpdateHelper,
                onRefreshStatus: onRefreshHelperStatus
            )
        }
    }

    @ViewBuilder
    private var launchAtLoginMessages: some View {
        if launchAtLoginController.needsApproval {
            Divider()
            SettingsNotice(
                message: "Approval needed in Login Items Settings.",
                color: .orange
            ) {
                SettingsGlassButton("Open Login Items Settings") {
                    launchAtLoginController.openLoginItemsSettings()
                }
            }
        }

        if let message = launchAtLoginController.lastErrorMessage, message.isEmpty == false {
            Divider()
            SettingsNotice(message: message, color: .red) {
                EmptyView()
            }
        }
    }
}

private struct DisplaySettingsPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsPane(
            title: "Display",
            subtitle: "Choose which device details appear in the scrollable panel area."
        ) {
            SettingsGroupTitle("Always Shown")

            SettingsCard {
                FixedPanelRow(title: "Overview", systemImage: "rectangle.grid.1x2")
                Divider()
                FixedPanelRow(title: "Throughput", systemImage: "waveform.path.ecg")
                Divider()
                FixedPanelRow(title: "Capacity", systemImage: "chart.bar.fill")
            }

            SettingsGroupTitle("Device Details")

            SettingsCard {
                ForEach(Array(PanelDetailSection.allCases.enumerated()), id: \.element) { index, section in
                    if index > 0 { Divider() }
                    SettingsControlRow(
                        title: section.title,
                        systemImage: section.systemImage
                    ) {
                        Toggle(
                            section.title,
                            isOn: Binding(
                                get: { settings[isVisible: section] },
                                set: { settings[isVisible: section] = $0 }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                }
            }
        }
    }
}

private struct SMARTHelperSettingsSection: View {
    @ObservedObject var manager: SMARTHelperManager
    let onInstallOrUpdate: () -> Void
    let onRefreshStatus: () -> Void

    private var presentation: SMARTHelperSettingsPresentation {
        SMARTHelperSettingsPresentation(status: manager.status)
    }

    var body: some View {
        SettingsGroupTitle("SMART Helper")

        SettingsCard {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: presentation.systemImage)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(presentation.color)
                    .frame(width: 34)

                VStack(alignment: .leading, spacing: 5) {
                    Text(presentation.title)
                        .font(.headline)

                    Text(presentation.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    if let errorMessage = presentation.errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }

                Spacer(minLength: 12)

                helperAction
                    .frame(width: 92, alignment: .trailing)
            }
        }

        Text("The helper is installed by macOS with administrator approval and is only used for SMART access and safe-eject occupancy checks.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var helperAction: some View {
        switch manager.status {
        case .checking, .installing:
            ProgressView()
                .controlSize(.small)
                .frame(width: 78, height: 28)
        case .notInstalled:
            SettingsGlassButton("Install", prominent: true, action: onInstallOrUpdate)
        case .companionUnavailable, .monitoringUpdateRequired, .updateRequired:
            SettingsGlassButton("Update", prominent: true, action: onInstallOrUpdate)
        case .installed:
            SettingsGlassButton("Check Again", action: onRefreshStatus)
        case .inspectionFailed:
            SettingsGlassButton("Try Again", action: onRefreshStatus)
        case .installationFailed:
            SettingsGlassButton("Try Again", prominent: true, action: onInstallOrUpdate)
        }
    }
}

struct SMARTHelperSettingsPresentation {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let systemImage: String
    let color: Color
    let errorMessage: String?

    init(status: SMARTHelperStatus) {
        switch status {
        case .notInstalled:
            self.init(
                title: "Not Installed",
                message: "Install the helper to enable health and temperature data.",
                systemImage: "exclamationmark.shield",
                color: .orange
            )
        case .checking:
            self.init(
                title: "Checking Status",
                message: "Palmos is checking the installed helper.",
                systemImage: "hourglass",
                color: .secondary
            )
        case .installed:
            self.init(
                title: "Installed",
                message: "Health and temperature monitoring is available.",
                systemImage: "checkmark.shield.fill",
                color: .green
            )
        case .companionUnavailable:
            self.init(
                title: "SMART Companion Unavailable",
                message: "The helper is installed, but its trusted smartctl companion is unavailable.",
                systemImage: "exclamationmark.shield.fill",
                color: .orange
            )
        case .monitoringUpdateRequired:
            self.init(
                title: "SMART Monitoring Update Required",
                message: "Safe-eject checks remain available, but SMART monitoring requires a helper update.",
                systemImage: "arrow.triangle.2.circlepath.circle",
                color: .orange
            )
        case .updateRequired:
            self.init(
                title: "Update Required",
                message: "Update the helper to match this version of Palmos.",
                systemImage: "arrow.triangle.2.circlepath.circle",
                color: .orange
            )
        case .installing:
            self.init(
                title: "Installing",
                message: "macOS may ask for administrator approval.",
                systemImage: "arrow.down.app",
                color: .accentColor
            )
        case .inspectionFailed(let error):
            self.init(
                title: "Status Unavailable",
                message: "Palmos could not verify the SMART helper.",
                systemImage: "xmark.shield",
                color: .red,
                errorMessage: error
            )
        case .installationFailed(let error):
            self.init(
                title: "Installation Failed",
                message: "The SMART Helper installation did not complete.",
                systemImage: "xmark.shield",
                color: .red,
                errorMessage: error
            )
        }
    }

    private init(
        title: LocalizedStringKey,
        message: LocalizedStringKey,
        systemImage: String,
        color: Color,
        errorMessage: String? = nil
    ) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.color = color
        self.errorMessage = errorMessage
    }

}
