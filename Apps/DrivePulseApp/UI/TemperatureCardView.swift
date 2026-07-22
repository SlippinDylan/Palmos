import SwiftUI

import DrivePulseCore

struct TemperatureCardView: View {
    let smartDetails: SMARTPresentationDetails?
    @ObservedObject var settings: AppSettings

    var body: some View {
        PanelSection("Temperature") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                temperatureRow(label: "Composite", celsius: smartData?.primaryTemperature)
                temperatureRow(label: "Sensor 1", celsius: sensor1Temperature)
                temperatureRow(label: "Sensor 2", celsius: sensor2Temperature)
                PanelKeyValueRow("Warning Threshold", value: warningThresholdString, usesMonospacedDigits: true)
                PanelKeyValueRow("Critical Threshold", value: criticalThresholdString, usesMonospacedDigits: true)
                PanelKeyValueRow("Warning Temp Time", value: warningTempTimeString, usesMonospacedDigits: true)
                PanelKeyValueRow("Critical Temp Time", value: criticalTempTimeString, usesMonospacedDigits: true)
            }
        }
    }

    private var smartData: SmartData? {
        guard case .available(let data) = smartDetails?.snapshot else { return nil }
        return data
    }

    private var sensor1Temperature: Int? {
        smartData?.sensorTemperatures["1"] ?? smartData?.sensorTemperatures["Sensor 1"]
    }

    private var sensor2Temperature: Int? {
        smartData?.sensorTemperatures["2"] ?? smartData?.sensorTemperatures["Sensor 2"]
    }

    private var warningThresholdString: String {
        guard let value = smartData?.warningTempThreshold else { return PanelDisplayValue.missing }
        return settings.temperatureUnit.format(value)
    }

    private var criticalThresholdString: String {
        guard let value = smartData?.criticalTempThreshold else { return PanelDisplayValue.missing }
        return settings.temperatureUnit.format(value)
    }

    private var warningTempTimeString: String {
        guard let value = smartData?.warningTempTime else { return PanelDisplayValue.missing }
        return PanelValueFormatter.minutes(value)
    }

    private var criticalTempTimeString: String {
        guard let value = smartData?.criticalTempTime else { return PanelDisplayValue.missing }
        return PanelValueFormatter.minutes(value)
    }

    @ViewBuilder
    private func temperatureRow(label: LocalizedStringKey, celsius: Int?) -> some View {
        if let celsius {
            PanelKeyValueRow(
                label,
                value: settings.temperatureUnit.format(celsius),
                valueColor: temperatureColor(celsius),
                usesMonospacedDigits: true
            )
        } else {
            PanelKeyValueRow(label, value: PanelDisplayValue.missing)
        }
    }
}

private func temperatureColor(_ celsius: Int) -> Color {
    if celsius > 75 { return .red }
    if celsius >= 60 { return .orange }
    return .primary
}
