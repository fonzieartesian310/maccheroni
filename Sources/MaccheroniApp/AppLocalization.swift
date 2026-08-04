import Foundation
import Observation

@MainActor
@Observable
final class AppLanguageStore {
    nonisolated static let defaultsKey = "appLanguage"

    @ObservationIgnored private let defaults: UserDefaults
    var rawValue: String {
        didSet { defaults.set(rawValue, forKey: Self.defaultsKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        rawValue = defaults.string(forKey: Self.defaultsKey) ?? AppLanguage.english.rawValue
    }

    var language: AppLanguage {
        AppLanguage(rawValue: rawValue) ?? .english
    }
}

let appResourcesBundle: Bundle = {
    if let url = Bundle.main.url(
        forResource: "Maccheroni_MaccheroniApp",
        withExtension: "bundle"
    ), let bundle = Bundle(url: url) {
        return bundle
    }
    return Bundle.module
}()

func appLocalized(
    _ keyAndValue: String.LocalizationValue,
    locale: Locale? = nil
) -> LocalizedStringResource {
    let resolvedLocale = locale ?? selectedAppLocale()
    return LocalizedStringResource(
        keyAndValue,
        locale: resolvedLocale,
        bundle: localizedAppBundle(for: resolvedLocale)
    )
}

func appString(
    _ keyAndValue: String.LocalizationValue,
    locale: Locale? = nil
) -> String {
    let resolvedLocale = locale ?? selectedAppLocale()
    return String(
        localized: keyAndValue,
        bundle: localizedAppBundle(for: resolvedLocale),
        locale: resolvedLocale
    )
}

private func localizedAppBundle(for locale: Locale) -> Bundle {
    let available = appResourcesBundle.localizations
    let preferred = Bundle.preferredLocalizations(
        from: available,
        forPreferences: [locale.identifier]
    )

    for candidate in preferred + [locale.identifier] {
        guard let localization = available.first(where: {
            $0.caseInsensitiveCompare(candidate) == .orderedSame
        }), let path = appResourcesBundle.path(
            forResource: localization,
            ofType: "lproj"
        ), let bundle = Bundle(path: path) else {
            continue
        }
        return bundle
    }

    return appResourcesBundle
}

private func selectedAppLocale(defaults: UserDefaults = .standard) -> Locale {
    let rawValue = defaults.string(forKey: AppLanguageStore.defaultsKey)
        ?? AppLanguage.english.rawValue
    return AppLanguage(rawValue: rawValue)?.locale ?? AppLanguage.english.locale
}
