import Foundation

enum L10n {
    nonisolated static func string(_ key: String.LocalizationValue) -> String {
        String(localized: key)
    }

    nonisolated static func format(
        _ key: String.LocalizationValue,
        _ arguments: CVarArg...
    ) -> String {
        String(
            format: String(localized: key),
            locale: Locale.current,
            arguments: arguments
        )
    }
}
