// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import HwattakPDF

@MainActor
final class PDFReadingThemeTests: XCTestCase {
    func testFirstLaunchAndUnrecognizedSavedThemeKeepOriginalColors() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(AppPreferences(defaults: defaults, appearanceDidChange: { _ in }).readingTheme, .original)
        for value in ["", "retired-theme", "NIGHT"] {
            defaults.set(value, forKey: PDFReadingTheme.defaultsKey)
            defaults.set(AppAppearance.light.rawValue, forKey: AppPreferences.appearanceDefaultsKey)
            let preferences = AppPreferences(defaults: defaults, appearanceDidChange: { _ in })
            XCTAssertEqual(preferences.readingTheme, .original)
            XCTAssertEqual(preferences.effectiveAppearance, .light)
            XCTAssertEqual(preferences.appearance, .light)
        }
    }

    func testEveryThemePersistsAndRestoresItsEffectiveAppearance() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(AppAppearance.light.rawValue, forKey: AppPreferences.appearanceDefaultsKey)
        var applied: [AppAppearance] = []
        let preferences = AppPreferences(defaults: defaults) { applied.append($0) }

        // Starting with a different choice exercises persistence of Original,
        // too, rather than relying on the same-value no-op on first launch.
        preferences.readingTheme = .night
        for theme in PDFReadingTheme.allCases {
            preferences.readingTheme = theme
            XCTAssertEqual(defaults.string(forKey: PDFReadingTheme.defaultsKey), theme.rawValue)
            XCTAssertEqual(preferences.appearance, .light)
            let expected: AppAppearance = theme == .night ? .dark : .light
            XCTAssertEqual(applied.last, expected)

            var restoredAppearance: AppAppearance?
            let restored = AppPreferences(defaults: defaults) { restoredAppearance = $0 }
            XCTAssertEqual(restored.readingTheme, theme)
            XCTAssertEqual(restored.appearance, .light)
            XCTAssertEqual(restored.effectiveAppearance, expected)
            restored.applyAppearance()
            XCTAssertEqual(restoredAppearance, expected)
        }
    }

    func testNightTemporarilyUsesDarkChromeAndRestoresEachUnderlyingAppearance() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        for base in AppAppearance.allCases {
            defaults.set(base.rawValue, forKey: AppPreferences.appearanceDefaultsKey)
            defaults.set(PDFReadingTheme.original.rawValue, forKey: PDFReadingTheme.defaultsKey)
            var applied: [AppAppearance] = []
            let preferences = AppPreferences(defaults: defaults) { applied.append($0) }

            for nextTheme in [PDFReadingTheme.original, .soft, .sepia] {
                preferences.readingTheme = .night
                XCTAssertEqual(preferences.effectiveAppearance, .dark)
                XCTAssertEqual(applied.last, .dark)
                XCTAssertEqual(preferences.appearance, base)
                XCTAssertEqual(defaults.string(forKey: AppPreferences.appearanceDefaultsKey), base.rawValue)

                preferences.readingTheme = nextTheme
                XCTAssertEqual(preferences.effectiveAppearance, base)
                XCTAssertEqual(applied.last, base)
                XCTAssertEqual(preferences.appearance, base)
                XCTAssertEqual(defaults.string(forKey: AppPreferences.appearanceDefaultsKey), base.rawValue)
            }
        }
    }

    func testChangingBaseAppearanceDuringNightTakesEffectWhenNightEnds() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(AppAppearance.dark.rawValue, forKey: AppPreferences.appearanceDefaultsKey)
        var applied: [AppAppearance] = []
        let preferences = AppPreferences(defaults: defaults) { applied.append($0) }

        preferences.readingTheme = .night
        preferences.appearance = .light
        XCTAssertEqual(preferences.appearance, .light)
        XCTAssertEqual(preferences.effectiveAppearance, .dark)
        XCTAssertEqual(applied.last, .dark)
        XCTAssertEqual(defaults.string(forKey: AppPreferences.appearanceDefaultsKey), AppAppearance.light.rawValue)

        // Relaunching while Night is active must retain the deferred choice.
        let restored = AppPreferences(defaults: defaults, appearanceDidChange: { _ in })
        XCTAssertEqual(restored.readingTheme, .night)
        XCTAssertEqual(restored.appearance, .light)
        XCTAssertEqual(restored.effectiveAppearance, .dark)

        preferences.readingTheme = .soft
        XCTAssertEqual(preferences.effectiveAppearance, .light)
        XCTAssertEqual(applied.last, .light)
        preferences.readingTheme = .night
        preferences.appearance = .system
        XCTAssertEqual(preferences.effectiveAppearance, .dark)
        preferences.readingTheme = .original
        XCTAssertEqual(preferences.effectiveAppearance, .system)
        XCTAssertEqual(applied.last, .system)
    }

    func testSelectingSameThemeDoesNotReapplyOrChangeIndependentPreferences() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(AppLanguage.french.rawValue, forKey: AppPreferences.languageDefaultsKey)
        defaults.set(AppAppearance.light.rawValue, forKey: AppPreferences.appearanceDefaultsKey)
        defaults.set(PDFReadingTheme.sepia.rawValue, forKey: PDFReadingTheme.defaultsKey)
        var applied: [AppAppearance] = []
        let preferences = AppPreferences(defaults: defaults) { applied.append($0) }

        preferences.readingTheme = .sepia
        XCTAssertTrue(applied.isEmpty)
        preferences.readingTheme = .night
        let countAfterChange = applied.count
        preferences.readingTheme = .night
        XCTAssertEqual(applied.count, countAfterChange)
        XCTAssertEqual(preferences.language, .french)
        XCTAssertEqual(preferences.appearance, .light)
        XCTAssertEqual(defaults.string(forKey: AppPreferences.languageDefaultsKey), AppLanguage.french.rawValue)
        XCTAssertEqual(defaults.string(forKey: AppPreferences.appearanceDefaultsKey), AppAppearance.light.rawValue)
    }

    func testReadingPapersReduceWhiteBrightnessWithoutClippingOrLosingBlackInkContrast() {
        var luminances: [PDFReadingTheme: Double] = [:]
        for theme in PDFReadingTheme.allCases {
            let paper = theme.paperRGB
            for component in [paper.red, paper.green, paper.blue] {
                XCTAssertTrue(component.isFinite, "\(theme) must not send non-finite values to display filters")
                XCTAssertGreaterThanOrEqual(component, 0)
                XCTAssertLessThanOrEqual(component, 1)
            }
            let luminance = relativeLuminance(red: paper.red, green: paper.green, blue: paper.blue)
            luminances[theme] = luminance
            // The view-only multiply transform preserves black ink. Even the
            // dimmest paper must retain readable normal-text contrast.
            XCTAssertGreaterThanOrEqual((luminance + 0.05) / 0.05, 4.5,
                                        "\(theme) must retain black-text contrast")
        }
        XCTAssertEqual(luminances[.original]!, 1, accuracy: 0.0001)
        XCTAssertLessThan(luminances[.soft]!, luminances[.original]!)
        XCTAssertLessThan(luminances[.sepia]!, luminances[.soft]!)
        XCTAssertLessThan(luminances[.night]!, luminances[.sepia]!)
    }

    private func relativeLuminance(red: Double, green: Double, blue: Double) -> Double {
        func linear(_ component: Double) -> Double {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suite = "HwattakPDF.PDFReadingThemeTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }
}
