import Foundation

/// Looks `key` up in the bundle's Localizable.strings (Resources/<lang>.lproj). The key is the
/// English text, so a missing translation, or `swift run` without a bundle, reads as English.
/// Arguments fill `%@` / `%d` placeholders in the translated format.
nonisolated func tr(_ key: String, _ arguments: CVarArg...) -> String {
    let format = Bundle.main.localizedString(forKey: key, value: key, table: nil)
    return arguments.isEmpty ? format : String(format: format, arguments: arguments)
}
