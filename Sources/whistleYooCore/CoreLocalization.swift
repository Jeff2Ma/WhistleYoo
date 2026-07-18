import Foundation

@inline(__always)
func coreLocalized(_ key: String) -> String {
    NSLocalizedString(key, tableName: nil, bundle: .main, value: key, comment: "")
}

func coreLocalizedFormat(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: coreLocalized(key), locale: Locale.current, arguments: arguments)
}
