import Foundation

enum L10n {
    static func tr(_ key: String) -> String {
        NSLocalizedString(key, bundle: .module, comment: "")
    }

    static func tr(_ key: String, _ arguments: CVarArg...) -> String {
        let format = tr(key)
        return String(format: format, locale: Locale.current, arguments: arguments)
    }
}
