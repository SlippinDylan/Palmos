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
            let converted = (Double(celsiusValue) * 9 / 5 + 32).rounded()
            let fahrenheitValue: Int
            if converted >= Double(Int.max) {
                fahrenheitValue = .max
            } else if converted <= Double(Int.min) {
                fahrenheitValue = .min
            } else {
                fahrenheitValue = Int(converted)
            }
            return "\(fahrenheitValue) °F"
        }
    }
}

public enum ApplicationLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"

    public var id: Self { self }
}

/// User-configurable sections in the menu bar panel's detail area.
/// Fixed content such as overview, throughput, and capacity deliberately stays outside this model.
public enum PanelDetailSection: String, CaseIterable, Identifiable, Sendable {
    case healthSMART
    case temperature
    case volumesPartitions
    case connectionNVMe
    case deviceIdentity

    public var id: Self { self }
}

public final class AppSettings: ObservableObject {
    public static let temperatureUnitDefaultsKey = "palmos.temperatureUnit"
    public static let hiddenPanelDetailSectionsDefaultsKey = "palmos.hiddenPanelDetailSections"
    public static let applicationLanguageDefaultsKey = "palmos.applicationLanguage"
    public static let appleLanguagesDefaultsKey = "AppleLanguages"

    @Published public var temperatureUnit: TemperatureUnit {
        didSet {
            defaults.set(temperatureUnit.rawValue, forKey: Self.temperatureUnitDefaultsKey)
        }
    }

    @Published private var hiddenPanelDetailSections: Set<PanelDetailSection> {
        didSet {
            defaults.set(
                hiddenPanelDetailSections.map(\.rawValue).sorted(),
                forKey: Self.hiddenPanelDetailSectionsDefaultsKey
            )
        }
    }

    @Published public private(set) var applicationLanguage: ApplicationLanguage

    public var visiblePanelDetailSections: Set<PanelDetailSection> {
        Set(PanelDetailSection.allCases).subtracting(hiddenPanelDetailSections)
    }

    /// A read-write visibility API that can be wrapped directly by a SwiftUI `Binding`.
    public subscript(isVisible section: PanelDetailSection) -> Bool {
        get {
            hiddenPanelDetailSections.contains(section) == false
        }
        set {
            if newValue {
                hiddenPanelDetailSections.remove(section)
            } else {
                hiddenPanelDetailSections.insert(section)
            }
        }
    }

    @discardableResult
    public func setApplicationLanguage(_ language: ApplicationLanguage) -> Bool {
        guard language != applicationLanguage else { return false }
        applicationLanguage = language
        defaults.set(language.rawValue, forKey: Self.applicationLanguageDefaultsKey)
        switch language {
        case .system:
            defaults.removeObject(forKey: Self.appleLanguagesDefaultsKey)
        case .english, .simplifiedChinese, .traditionalChinese:
            defaults.set([language.rawValue], forKey: Self.appleLanguagesDefaultsKey)
        }
        return true
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.temperatureUnit = TemperatureUnit(
            rawValue: defaults.string(forKey: Self.temperatureUnitDefaultsKey) ?? ""
        ) ?? .celsius
        self.hiddenPanelDetailSections = Set(
            defaults.stringArray(forKey: Self.hiddenPanelDetailSectionsDefaultsKey)?
                .compactMap(PanelDetailSection.init(rawValue:)) ?? []
        )
        self.applicationLanguage = defaults.string(forKey: Self.applicationLanguageDefaultsKey)
            .flatMap(ApplicationLanguage.init(rawValue:)) ?? .system
    }
}
