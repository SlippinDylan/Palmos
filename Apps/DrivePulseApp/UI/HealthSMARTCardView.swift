import SwiftUI

import DrivePulseCore

struct HealthSMARTCardView: View {
    let smartDetails: SMARTPresentationDetails?
    let onRefresh: () -> Void

    var body: some View {
        PanelSection("Health & SMART") {
            VStack(alignment: .leading, spacing: 0) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.bottom, 6)
                }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    PanelKeyValueRow("Overall Health", value: healthString)
                    PanelKeyValueRow("Critical Warning", value: criticalWarningString, usesMonospacedDigits: true)
                    PanelKeyValueRow("Wear Level", value: wearLevelString, usesMonospacedDigits: true)
                    PanelKeyValueRow("Available Spare", value: availableSpareString, usesMonospacedDigits: true)
                    PanelKeyValueRow("Media Integrity Errors", value: mediaIntegrityErrorsString, usesMonospacedDigits: true)
                    PanelKeyValueRow("Error Log Entries", value: errorLogEntriesString, usesMonospacedDigits: true)
                }

                if isDegraded {
                    Text(PanelValueFormatter.degradedNotice())
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                }

                Divider()
                    .padding(.vertical, 6)

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    PanelKeyValueRow("Power-On Hours", value: powerOnHoursString, usesMonospacedDigits: true)
                    PanelKeyValueRow("Power Cycles", value: powerCyclesString, usesMonospacedDigits: true)
                    PanelKeyValueRow("Unsafe Shutdowns", value: unsafeShutdownsString, usesMonospacedDigits: true)
                    PanelKeyValueRow("Total Written", value: totalWrittenString, usesMonospacedDigits: true)
                    PanelKeyValueRow("Total Read", value: totalReadString, usesMonospacedDigits: true)
                    PanelKeyValueRow("Controller Busy Time", value: controllerBusyTimeString, usesMonospacedDigits: true)
                    PanelKeyValueRow("Warning Temp Time", value: warningTempTimeString, usesMonospacedDigits: true)
                    PanelKeyValueRow("Critical Temp Time", value: criticalTempTimeString, usesMonospacedDigits: true)
                }

                if !isLoading && canRefresh {
                    Button("Refresh SMART Data") { onRefresh() }
                        .buttonStyle(.link)
                        .controlSize(.small)
                        .padding(.top, 8)
                }
            }
        }
    }

    private var smartData: SmartData? {
        guard case .available(let data) = smartDetails?.snapshot else { return nil }
        return data
    }

    private var isLoading: Bool {
        guard let snapshot = smartDetails?.snapshot else { return false }
        if case .loading = snapshot { return true }
        return false
    }

    private var canRefresh: Bool {
        guard let snapshot = smartDetails?.snapshot else { return false }
        switch snapshot {
        case .companionUnavailable, .helperNotInstalled, .updateRequired:
            return false
        default:
            return true
        }
    }

    private var healthString: String {
        guard let health = smartData?.overallHealth else { return PanelDisplayValue.missing }
        return PanelValueFormatter.health(health)
    }

    private var isDegraded: Bool {
        guard let quality = smartData?.parsingQuality else { return false }
        if case .degraded = quality { return true }
        return false
    }

    private var criticalWarningString: String {
        guard let cw = smartData?.criticalWarning else { return PanelDisplayValue.missing }
        let hex = String(format: "0x%02X", cw)
        return cw == 0 ? PanelValueFormatter.criticalWarning(hex: hex) : hex
    }

    private var wearLevelString: String {
        guard let pct = smartData?.percentageUsed else { return PanelDisplayValue.missing }
        return "\(pct)%"
    }

    private var availableSpareString: String {
        guard let spare = smartData?.availableSpare else { return PanelDisplayValue.missing }
        guard let threshold = smartData?.availableSpareThreshold else { return "\(spare)%" }
        return PanelValueFormatter.availableSpare(spare, threshold: threshold)
    }

    private var mediaIntegrityErrorsString: String {
        guard let value = smartData?.mediaIntegrityErrors else { return PanelDisplayValue.missing }
        return "\(value)"
    }

    private var errorLogEntriesString: String {
        guard let value = smartData?.errorLogEntries else { return PanelDisplayValue.missing }
        return "\(value)"
    }

    private var powerOnHoursString: String {
        guard let value = smartData?.powerOnHours else { return PanelDisplayValue.missing }
        return PanelValueFormatter.hours(value)
    }

    private var powerCyclesString: String {
        guard let value = smartData?.powerCycles else { return PanelDisplayValue.missing }
        return "\(value)"
    }

    private var unsafeShutdownsString: String {
        guard let us = smartData?.unsafeShutdowns else { return PanelDisplayValue.missing }
        var text = "\(us)"
        if let pc = smartData?.powerCycles, pc > 0, Double(us) / Double(pc) > 0.15 {
            text += " ⚠️"
        }
        return text
    }

    private var totalWrittenString: String {
        guard let units = smartData?.dataUnitsWritten else { return PanelDisplayValue.missing }
        return byteCountString(forDataUnits: units)
    }

    private var totalReadString: String {
        guard let units = smartData?.dataUnitsRead else { return PanelDisplayValue.missing }
        return byteCountString(forDataUnits: units)
    }

    private func byteCountString(forDataUnits units: UInt64) -> String {
        let maxUnits = UInt64(Int64.max / 512_000)
        let bytes = units > maxUnits
            ? Int64.max
            : Int64(units) * 512_000
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var controllerBusyTimeString: String {
        guard let value = smartData?.controllerBusyTime else { return PanelDisplayValue.missing }
        return PanelValueFormatter.minutes(value)
    }

    private var warningTempTimeString: String {
        guard let value = smartData?.warningTempTime else { return PanelDisplayValue.missing }
        return PanelValueFormatter.minutes(value)
    }

    private var criticalTempTimeString: String {
        guard let value = smartData?.criticalTempTime else { return PanelDisplayValue.missing }
        return PanelValueFormatter.minutes(value)
    }
}

struct SMARTHelperPlaceholderView: View {
    let requiresUpdate: Bool
    let onOpenSettings: () -> Void

    var body: some View {
        PanelSection("Advanced Monitoring") {
            VStack(spacing: 10) {
                Image(systemName: "stethoscope.circle")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Text(requiresUpdate ? "Update Required" : "Helper required")
                    .font(.subheadline.weight(.semibold))

                Text("Open Settings to install or update the SMART helper.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                openSettingsButton
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var openSettingsButton: some View {
        let button = Button("Settings", action: onOpenSettings)
            .controlSize(.small)

        if #available(macOS 26.0, *) {
            button.buttonStyle(.glass)
        } else {
            button.buttonStyle(.bordered)
        }
    }
}
