import SwiftUI

import DrivePulseCore

struct TemperatureCardView: View {
    let smartDetails: SMARTPresentationDetails?
    @ObservedObject var settings: AppSettings

    var body: some View {
        PanelSection("Temperature") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                TemperatureRow(label: "Composite", celsius: smartData?.primaryTemperature, unit: settings.temperatureUnit)
                TemperatureRow(label: "Sensor 1", celsius: sensor1Temperature, unit: settings.temperatureUnit)
                TemperatureRow(label: "Sensor 2", celsius: sensor2Temperature, unit: settings.temperatureUnit)
                InfoRow("Warning Threshold", value: warningThresholdString)
                InfoRow("Critical Threshold", value: criticalThresholdString)
                InfoRow("Warning Temp Time", value: warningTempTimeString)
                InfoRow("Critical Temp Time", value: criticalTempTimeString)
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
        return "\(value) min"
    }

    private var criticalTempTimeString: String {
        guard let value = smartData?.criticalTempTime else { return PanelDisplayValue.missing }
        return "\(value) min"
    }
}

private func temperatureColor(_ celsius: Int) -> Color {
    if celsius > 75 { return .red }
    if celsius >= 60 { return .orange }
    return .primary
}

private struct TemperatureRow: View {
    let label: LocalizedStringKey
    let celsius: Int?
    let unit: TemperatureUnit

    var body: some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            if let celsius {
                Text(unit.format(celsius))
                    .foregroundStyle(temperatureColor(celsius))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                Text(PanelDisplayValue.missing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}

private struct InfoRow: View {
    let label: LocalizedStringKey
    let value: String

    init(_ label: LocalizedStringKey, value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}
