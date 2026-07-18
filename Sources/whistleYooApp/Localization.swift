import Foundation

@inline(__always)
func appLocalized(_ key: String) -> String {
    #if SWIFT_PACKAGE
    let bundle = Bundle.module
    #else
    let bundle = Bundle.main
    #endif
    return NSLocalizedString(key, tableName: nil, bundle: bundle, value: key, comment: "")
}

func appLocalizedFormat(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: appLocalized(key), locale: Locale.current, arguments: arguments)
}
