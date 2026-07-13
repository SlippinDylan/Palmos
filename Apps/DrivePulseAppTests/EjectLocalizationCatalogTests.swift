import Foundation
import XCTest

final class EjectLocalizationCatalogTests: XCTestCase {
    func testEveryEjectKeyHasThreeTranslatedLocalesAndMatchingPlaceholders() throws {
        let catalog = try loadCatalog()
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        let ejectEntries = strings.filter { $0.key.hasPrefix("eject.") }

        XCTAssertFalse(ejectEntries.isEmpty)
        for (key, rawEntry) in ejectEntries {
            let entry = try XCTUnwrap(rawEntry as? [String: Any], key)
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], key)
            let values = try ["en", "zh-Hans", "zh-Hant"].map { locale -> String in
                let localization = try XCTUnwrap(localizations[locale] as? [String: Any], "\(key) \(locale)")
                let unit = try XCTUnwrap(localization["stringUnit"] as? [String: Any], "\(key) \(locale)")
                XCTAssertEqual(unit["state"] as? String, "translated", "\(key) \(locale)")
                return try XCTUnwrap(unit["value"] as? String, "\(key) \(locale)")
            }
            XCTAssertEqual(placeholderSignature(values[0]), placeholderSignature(values[1]), key)
            XCTAssertEqual(placeholderSignature(values[0]), placeholderSignature(values[2]), key)
        }
    }

    func testSuccessAndDisappearanceKeysAreDistinct() throws {
        let strings = try XCTUnwrap(try loadCatalog()["strings"] as? [String: Any])
        XCTAssertNotNil(strings["eject.result.safeToRemove"])
        XCTAssertNotNil(strings["eject.result.deviceDisappeared"])
    }

    private func loadCatalog() throws -> [String: Any] {
        let testFile = URL(fileURLWithPath: #filePath)
        let catalogURL = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("DrivePulseApp/Localization/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func placeholderSignature(_ value: String) -> [String] {
        let pattern = #"%(?:\d+\$)?(?:[-+0 #']*)?(?:\d+|\*)?(?:\.\d+|\.\*)?(?:hh|h|ll|l|q|z|t|j)?[@dDuUxXfFeEgGcCsSpaA]"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(value.startIndex..., in: value)
        return regex.matches(in: value, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: value) else { return nil }
            return String(value[swiftRange])
        }
    }
}
