// SPDX-License-Identifier: MPL-2.0

import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case korean = "ko"
    case english = "en"
    case japanese = "ja"
    case simplifiedChinese = "zh-Hans"
    case vietnamese = "vi"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case russian = "ru"
    case arabic = "ar"

    var id: String { rawValue }

    var nativeName: String {
        switch self {
        case .korean: "한국어"
        case .english: "English"
        case .french: "Français"
        case .german: "Deutsch"
        case .spanish: "Español"
        case .japanese: "日本語"
        case .simplifiedChinese: "简体中文"
        case .arabic: "العربية"
        case .russian: "Русский"
        case .vietnamese: "Tiếng Việt"
        }
    }

    var localeIdentifier: String {
        switch self {
        case .korean: "ko-KR"
        case .english: "en-US"
        case .french: "fr-FR"
        case .german: "de-DE"
        case .spanish: "es-ES"
        case .japanese: "ja-JP"
        case .simplifiedChinese: "zh-Hans-CN"
        case .arabic: "ar"
        case .russian: "ru-RU"
        case .vietnamese: "vi-VN"
        }
    }

    var locale: Locale { Locale(identifier: localeIdentifier) }

    var layoutDirection: LayoutDirection {
        self == .arabic ? .rightToLeft : .leftToRight
    }

    /// Portuguese was available before build 30. Keep those users in a
    /// readable fallback rather than silently switching their UI to Korean.
    static func savedPreference(_ rawValue: String?) -> Self {
        if rawValue == "pt" { return .english }
        return rawValue.flatMap(Self.init(rawValue:)) ?? .korean
    }
}

@MainActor
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()
    nonisolated static let languageDefaultsKey = "preferences.appLanguage"
    nonisolated static let appearanceDefaultsKey = "preferences.appAppearance"

    private let defaults: UserDefaults
    private let appearanceDidChange: @MainActor (AppAppearance) -> Void

    @Published var language: AppLanguage {
        didSet {
            guard language != oldValue else { return }
            defaults.set(language.rawValue, forKey: Self.languageDefaultsKey)
            NotificationCenter.default.post(name: .appLanguageDidChange, object: language)
        }
    }

    @Published var appearance: AppAppearance {
        didSet {
            guard appearance != oldValue else { return }
            defaults.set(appearance.rawValue, forKey: Self.appearanceDefaultsKey)
            applyAppearance()
        }
    }

    @Published var readingTheme: PDFReadingTheme {
        didSet {
            guard readingTheme != oldValue else { return }
            defaults.set(readingTheme.rawValue, forKey: PDFReadingTheme.defaultsKey)
            applyAppearance()
        }
    }

    /// Night reading changes native controls too, while remembering the base
    /// appearance to restore when the reader returns to another paper color.
    var effectiveAppearance: AppAppearance {
        readingTheme == .night ? .dark : appearance
    }

    init(
        defaults: UserDefaults = .standard,
        appearanceDidChange: @escaping @MainActor (AppAppearance) -> Void = { $0.apply() }
    ) {
        self.defaults = defaults
        self.appearanceDidChange = appearanceDidChange
        let storedLanguage = defaults.string(forKey: Self.languageDefaultsKey)
        let restoredLanguage = AppLanguage.savedPreference(storedLanguage)
        language = restoredLanguage
        if storedLanguage == "pt" {
            defaults.set(restoredLanguage.rawValue, forKey: Self.languageDefaultsKey)
        }
        appearance = defaults.string(forKey: Self.appearanceDefaultsKey)
            .flatMap(AppAppearance.init(rawValue:)) ?? .system
        readingTheme = defaults.string(forKey: PDFReadingTheme.defaultsKey)
            .flatMap(PDFReadingTheme.init(rawValue:)) ?? .original
    }

    func applyAppearance() {
        appearanceDidChange(effectiveAppearance)
    }

    nonisolated static var savedLanguage: AppLanguage {
        AppLanguage.savedPreference(UserDefaults.standard.string(forKey: languageDefaultsKey))
    }
}

extension Notification.Name {
    static let appLanguageDidChange = Notification.Name("HwattakPDF.appLanguageDidChange")
}

enum L10n {
    static func string(_ key: String, defaultValue: String? = nil) -> String {
        if let localizedBundle {
            return localizedBundle.localizedString(
                forKey: key,
                value: defaultValue ?? key,
                table: "Localizable"
            )
        }

        #if DEBUG
        // A bare debug SwiftPM executable/test host has no app resource
        // directory. Release builds never embed or inspect a source path.
        let stringsURL = sourceLocalizationDirectory
            .appendingPathComponent("\(currentLanguage.rawValue).lproj", isDirectory: true)
            .appendingPathComponent("Localizable.strings")
        if
            let data = try? Data(contentsOf: stringsURL),
            let table = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: String],
            let value = table[key]
        {
            return value
        }
        #endif
        return defaultValue ?? key
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        let format = string(key)
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: currentLanguage.locale, arguments: arguments)
    }

    static var currentLanguage: AppLanguage {
        AppPreferences.savedLanguage
    }

    private static var localizedBundle: Bundle? {
        let language = currentLanguage
        if let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        return nil
    }

    #if DEBUG
    private static var sourceLocalizationDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Localization", isDirectory: true)
    }
    #endif
}
