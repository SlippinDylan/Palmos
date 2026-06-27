import Combine
import Foundation

public enum TemperatureUnit: String, CaseIterable, Identifiable, Sendable {
    case celsius
    case fahrenheit

    public var id: Self { self }

    public func format(_ celsiusValue: Int) -> String {
        switch self {
        case .celsius:
            return "\(celsiusValue) °C"
        case .fahrenheit:
            let fahrenheitValue = Int((Double(celsiusValue) * 9 / 5 + 32).rounded())
            return "\(fahrenheitValue) °F"
        }
    }
}

public final class AppSettings: ObservableObject {
    public static let temperatureUnitDefaultsKey = "drivepulse.temperatureUnit"

    @Published public var temperatureUnit: TemperatureUnit {
        didSet {
            defaults.set(temperatureUnit.rawValue, forKey: Self.temperatureUnitDefaultsKey)
        }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.temperatureUnit = TemperatureUnit(
            rawValue: defaults.string(forKey: Self.temperatureUnitDefaultsKey) ?? ""
        ) ?? .celsius
    }
}
