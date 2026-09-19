import XCTest
@testable import PalmosCore

final class AppSettingsTests: XCTestCase {
    func testFahrenheitFormattingSaturatesExtremeIntegers() {
        XCTAssertEqual(TemperatureUnit.fahrenheit.format(.max), "\(Int.max) °F")
        XCTAssertEqual(TemperatureUnit.fahrenheit.format(.min), "\(Int.min) °F")
    }

    func testPanelDetailSectionsContainOnlyConfigurableDetailCards() {
        XCTAssertEqual(
            PanelDetailSection.allCases,
            [
                .healthSMART,
                .temperature,
                .volumesPartitions,
                .connectionNVMe,
                .deviceIdentity
            ]
        )
    }

    func testAllPanelDetailSectionsAreVisibleByDefault() {
        withIsolatedDefaults { defaults, _ in
            let settings = AppSettings(defaults: defaults)

            XCTAssertEqual(
                settings.visiblePanelDetailSections,
                Set(PanelDetailSection.allCases)
            )
            for section in PanelDetailSection.allCases {
                XCTAssertTrue(settings[isVisible: section])
            }
        }
    }

    func testEachPanelDetailSectionVisibilityPersistsIndependently() {
        withIsolatedDefaults { defaults, _ in
            let settings = AppSettings(defaults: defaults)

            for section in PanelDetailSection.allCases {
                settings[isVisible: section] = false

                let restoredHidden = AppSettings(defaults: defaults)
                XCTAssertFalse(restoredHidden[isVisible: section])
                XCTAssertEqual(
                    restoredHidden.visiblePanelDetailSections,
                    Set(PanelDetailSection.allCases).subtracting([section])
                )

                settings[isVisible: section] = true

                let restoredVisible = AppSettings(defaults: defaults)
                XCTAssertTrue(restoredVisible[isVisible: section])
                XCTAssertEqual(
                    restoredVisible.visiblePanelDetailSections,
                    Set(PanelDetailSection.allCases)
                )
            }
        }
    }

    func testUnknownPersistedSectionsDoNotHideKnownOrFutureSections() {
        withIsolatedDefaults { defaults, _ in
            defaults.set(
                [PanelDetailSection.temperature.rawValue, "futureSection"],
                forKey: AppSettings.hiddenPanelDetailSectionsDefaultsKey
            )

            let settings = AppSettings(defaults: defaults)

            XCTAssertFalse(settings[isVisible: .temperature])
            XCTAssertEqual(
                settings.visiblePanelDetailSections,
                Set(PanelDetailSection.allCases).subtracting([.temperature])
            )
        }
    }

    func testApplicationLanguageDefaultsToFollowingTheSystem() {
        withIsolatedDefaults { defaults, suiteName in
            let settings = AppSettings(defaults: defaults)

            XCTAssertEqual(settings.applicationLanguage, .system)
            XCTAssertNil(
                defaults.persistentDomain(forName: suiteName)?[AppSettings.appleLanguagesDefaultsKey]
            )
        }
    }

    func testApplicationLanguagePersistsOverridesAndRestoresSystemDefault() {
        withIsolatedDefaults { defaults, suiteName in
            let settings = AppSettings(defaults: defaults)

            XCTAssertTrue(settings.setApplicationLanguage(.english))
            XCTAssertEqual(defaults.stringArray(forKey: AppSettings.appleLanguagesDefaultsKey), ["en"])
            XCTAssertFalse(settings.setApplicationLanguage(.english))

            XCTAssertTrue(settings.setApplicationLanguage(.simplifiedChinese))
            XCTAssertEqual(defaults.stringArray(forKey: AppSettings.appleLanguagesDefaultsKey), ["zh-Hans"])

            XCTAssertTrue(settings.setApplicationLanguage(.traditionalChinese))
            XCTAssertEqual(defaults.stringArray(forKey: AppSettings.appleLanguagesDefaultsKey), ["zh-Hant"])
            XCTAssertEqual(
                AppSettings(defaults: defaults).applicationLanguage,
                .traditionalChinese
            )

            XCTAssertTrue(settings.setApplicationLanguage(.system))
            XCTAssertNil(
                defaults.persistentDomain(forName: suiteName)?[AppSettings.appleLanguagesDefaultsKey]
            )
            XCTAssertEqual(AppSettings(defaults: defaults).applicationLanguage, .system)
        }
    }

    func testApplicationLanguageOffersTheSupportedCatalogLocales() {
        XCTAssertEqual(
            ApplicationLanguage.allCases,
            [.system, .english, .simplifiedChinese, .traditionalChinese]
        )
    }

    private func withIsolatedDefaults(_ operation: (UserDefaults, String) -> Void) {
        let suiteName = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        operation(defaults, suiteName)
    }
}
