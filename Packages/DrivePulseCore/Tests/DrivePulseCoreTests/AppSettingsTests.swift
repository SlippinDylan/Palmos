import XCTest
@testable import DrivePulseCore

final class AppSettingsTests: XCTestCase {
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
        withIsolatedDefaults { defaults in
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
        withIsolatedDefaults { defaults in
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
        withIsolatedDefaults { defaults in
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

    private func withIsolatedDefaults(_ operation: (UserDefaults) -> Void) {
        let suiteName = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        operation(defaults)
    }
}
