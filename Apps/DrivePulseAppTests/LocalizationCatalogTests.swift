import Foundation
import XCTest

final class LocalizationCatalogTests: XCTestCase {
    private let requiredKeys = [
        "About", "Bus", "Copyright © 2025-2026 SlippinDylan Studio", "DrivePulse",
        "IEEE OUI", "Monitor external storage health and performance at a glance.",
        "Name", "Partition Type", "Version %@",
        "PCI Device ID", "PCI Vendor ID", "Receptacle", "Settings Bridge",
        "Size", "SMART", "UID", "Yes", "No", "SMART Passed", "SMART Failed",
        "No warnings", "SMART data partially available", "Threshold %@%%",
        "Bus %@", "Receptacle %@", "Duration minutes", "Duration hours", "Rate per second",
        "Critical warning %@ (%@)", "Available spare %@ (threshold %@%%)"
    ]

    func testRequiredPresentationKeysHaveAllTranslatedLocales() throws {
        let strings = try XCTUnwrap(try loadCatalog()["strings"] as? [String: Any])
        for key in requiredKeys {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], key)
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], key)
            for locale in ["en", "zh-Hans", "zh-Hant"] {
                let localization = try XCTUnwrap(localizations[locale] as? [String: Any], "\(key) \(locale)")
                let unit = try XCTUnwrap(localization["stringUnit"] as? [String: Any], "\(key) \(locale)")
                XCTAssertEqual(unit["state"] as? String, "translated", "\(key) \(locale)")
                XCTAssertFalse((unit["value"] as? String ?? "").isEmpty, "\(key) \(locale)")
            }
        }
    }

    func testPresentationPlaceholdersMatchAcrossLocales() throws {
        let strings = try XCTUnwrap(try loadCatalog()["strings"] as? [String: Any])
        for key in requiredKeys {
            guard let entry = strings[key] as? [String: Any],
                  let localizations = entry["localizations"] as? [String: Any] else { continue }
            let values = try ["en", "zh-Hans", "zh-Hant"].map { locale -> String in
                let localization = try XCTUnwrap(localizations[locale] as? [String: Any], "\(key) \(locale)")
                let unit = try XCTUnwrap(localization["stringUnit"] as? [String: Any], "\(key) \(locale)")
                return try XCTUnwrap(unit["value"] as? String)
            }
            XCTAssertEqual(signature(values[0]), signature(values[1]), key)
            XCTAssertEqual(signature(values[0]), signature(values[2]), key)
        }
    }

    func testBooleanHealthAndDegradedValuesHaveDistinctChineseTranslations() throws {
        let strings = try XCTUnwrap(try loadCatalog()["strings"] as? [String: Any])
        XCTAssertEqual(try value(for: "Yes", locale: "zh-Hans", strings: strings), "是")
        XCTAssertEqual(try value(for: "No", locale: "zh-Hant", strings: strings), "否")
        XCTAssertEqual(try value(for: "SMART Passed", locale: "zh-Hans", strings: strings), "通过")
        XCTAssertEqual(try value(for: "SMART Failed", locale: "zh-Hant", strings: strings), "失敗")
        XCTAssertEqual(try value(for: "SMART data partially available", locale: "zh-Hans", strings: strings), "SMART 数据部分可用")
    }

    func testUnitsAndRateUseLocalizedCatalogTemplates() throws {
        let strings = try XCTUnwrap(try loadCatalog()["strings"] as? [String: Any])
        XCTAssertTrue(try value(for: "Duration minutes", locale: "zh-Hans", strings: strings).contains("分钟"))
        XCTAssertTrue(try value(for: "Duration hours", locale: "zh-Hant", strings: strings).contains("小時"))
        XCTAssertTrue(try value(for: "Rate per second", locale: "zh-Hans", strings: strings).contains("每秒"))
    }

    func testAboutPageUsesExpectedChineseTranslations() throws {
        let strings = try XCTUnwrap(try loadCatalog()["strings"] as? [String: Any])

        XCTAssertEqual(try value(for: "About", locale: "zh-Hans", strings: strings), "关于")
        XCTAssertEqual(try value(for: "About", locale: "zh-Hant", strings: strings), "關於")
        XCTAssertEqual(try value(for: "Version %@", locale: "zh-Hans", strings: strings), "版本 %@")
        XCTAssertEqual(try value(for: "Version %@", locale: "zh-Hant", strings: strings), "版本 %@")
    }

    private func loadCatalog() throws -> [String: Any] {
        let testFile = URL(fileURLWithPath: #filePath)
        let url = testFile.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DrivePulseApp/Localization/Localizable.xcstrings")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func signature(_ value: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"%(?:\d+\$)?(?:[-+0 #']*)?(?:\d+|\*)?(?:\.\d+|\.\*)?(?:hh|h|ll|l|q|z|t|j)?[@dDuUxXfFeEgGcCsSpaA]"#)
        let range = NSRange(value.startIndex..., in: value)
        return regex.matches(in: value, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: value) else { return nil }
            return String(value[matchRange])
        }
    }

    private func value(for key: String, locale: String, strings: [String: Any]) throws -> String {
        let entry = try XCTUnwrap(strings[key] as? [String: Any], key)
        let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], key)
        let localization = try XCTUnwrap(localizations[locale] as? [String: Any], "\(key) \(locale)")
        let unit = try XCTUnwrap(localization["stringUnit"] as? [String: Any], "\(key) \(locale)")
        return try XCTUnwrap(unit["value"] as? String)
    }
}
