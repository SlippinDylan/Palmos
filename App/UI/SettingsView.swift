import AppKit
import SwiftUI

import PalmosCore

enum SettingsCategory: Int, CaseIterable {
    case general
    case display
    case about

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .display: String(localized: "Display")
        case .about: String(localized: "About")
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .display: "rectangle.3.group"
        case .about: "info.circle"
        }
    }

    var toolbarItemIdentifier: NSToolbarItem.Identifier {
        NSToolbarItem.Identifier("palmos-settings.\(rawValue)")
    }

    init?(toolbarItemIdentifier: NSToolbarItem.Identifier) {
        guard let category = Self.allCases.first(where: {
            $0.toolbarItemIdentifier == toolbarItemIdentifier
        }) else {
            return nil
        }
        self = category
    }
}

struct SettingsView: View {
    let category: SettingsCategory
    @ObservedObject var settings: AppSettings
    @ObservedObject var launchAtLoginController: LaunchAtLoginController
    @ObservedObject var smartHelperManager: SMARTHelperManager
    let onInstallOrUpdateHelper: () -> Void
    let onRefreshHelperStatus: () -> Void
    let onRequestRelaunch: () -> Void
    let canCheckForUpdates: () -> Bool
    let onCheckForUpdates: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            Group {
                switch category {
                case .general:
                GeneralSettingsPane(
                    settings: settings,
                    launchAtLoginController: launchAtLoginController,
                    smartHelperManager: smartHelperManager,
                    onInstallOrUpdateHelper: onInstallOrUpdateHelper,
                    onRefreshHelperStatus: onRefreshHelperStatus,
                    onRequestRelaunch: onRequestRelaunch
                )
                case .display:
                    DisplaySettingsPane(settings: settings)
                case .about:
                    AboutSettingsPane(
                        canCheckForUpdates: canCheckForUpdates,
                        onCheckForUpdates: onCheckForUpdates
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettingsPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var launchAtLoginController: LaunchAtLoginController
    @ObservedObject var smartHelperManager: SMARTHelperManager
    let onInstallOrUpdateHelper: () -> Void
    let onRefreshHelperStatus: () -> Void
    let onRequestRelaunch: () -> Void
    @State private var showsLanguageRestartPrompt = false

    var body: some View {
        SettingsPane {
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

            SettingsGroupTitle("Language")

            SettingsCard {
                SettingsControlRow(
                    title: "App Language",
                    systemImage: "globe"
                ) {
                    Picker(
                        "App Language",
                        selection: Binding(
                            get: { settings.applicationLanguage },
                            set: { language in
                                guard settings.setApplicationLanguage(language) else { return }
                                showsLanguageRestartPrompt = true
                            }
                        )
                    ) {
                        ForEach(ApplicationLanguage.allCases) { language in
                            Text(language.title).tag(language)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
            }

            SMARTHelperSettingsSection(
                manager: smartHelperManager,
                onInstallOrUpdate: onInstallOrUpdateHelper,
                onRefreshStatus: onRefreshHelperStatus
            )
        }
        .alert(
            "Restart Palmos to Change Language?",
            isPresented: $showsLanguageRestartPrompt
        ) {
            Button("Later", role: .cancel) {}
            Button("Restart Now", action: onRequestRelaunch)
        } message: {
            Text("Palmos will quit and reopen using the selected language.")
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

private extension ApplicationLanguage {
    var title: LocalizedStringKey {
        switch self {
        case .system: "Follow System"
        case .english: "English"
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        }
    }
}

private struct DisplaySettingsPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsPane {
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
            .padding(.vertical, 8)
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
            SettingsGlassButton("Repair", prominent: true, action: onInstallOrUpdate)
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
