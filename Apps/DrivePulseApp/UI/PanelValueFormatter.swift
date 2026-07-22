import Foundation

import DrivePulseCore

enum PanelValueFormatter {
    static func bus(_ value: String, locale: Locale = .current) -> String {
        format("Bus %@", locale: locale, value)
    }

    static func receptacle(_ value: String, locale: Locale = .current) -> String {
        format("Receptacle %@", locale: locale, value)
    }

    static func yesNo(_ value: Bool, locale: Locale = .current) -> String {
        String(localized: value ? "Yes" : "No", locale: locale)
    }

    static func minutes(_ value: UInt64, locale: Locale = .current) -> String {
        format("Duration minutes", locale: locale, String(value))
    }

    static func hours(_ value: UInt64, locale: Locale = .current) -> String {
        format("Duration hours", locale: locale, String(value))
    }

    static func rate(bytesPerSecond: Int64, locale: Locale = .current) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let count = formatter.string(fromByteCount: max(bytesPerSecond, 0))
        return format("Rate per second", locale: locale, count)
    }

    static func health(_ value: SMARTOverallHealth, locale: Locale = .current) -> String {
        String(localized: value == .passed ? "SMART Passed" : "SMART Failed", locale: locale)
    }

    static func noWarnings(locale: Locale = .current) -> String {
        String(localized: "No warnings", locale: locale)
    }

    static func criticalWarning(hex: String, locale: Locale = .current) -> String {
        format("Critical warning %@ (%@)", locale: locale, hex, noWarnings(locale: locale))
    }

    static func threshold(_ value: Int, locale: Locale = .current) -> String {
        format("Threshold %@%%", locale: locale, String(value))
    }

    static func availableSpare(_ spare: Int, threshold: Int, locale: Locale = .current) -> String {
        format("Available spare %@ (threshold %@%%)", locale: locale, String(spare), String(threshold))
    }

    static func degradedNotice(locale: Locale = .current) -> String {
        String(localized: "SMART data partially available", locale: locale)
    }

    private static func format(_ key: String, locale: Locale, _ values: String...) -> String {
        let localizedKey = String(localized: String.LocalizationValue(stringLiteral: key), locale: locale)
        return String(format: localizedKey, locale: locale, arguments: values.map { $0 as CVarArg })
    }
}
