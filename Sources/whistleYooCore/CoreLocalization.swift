import Foundation

public enum Localization {
    public static var bundle: Bundle {
        #if SWIFT_PACKAGE
        Bundle.module
        #else
        Bundle.main
        #endif
    }

    @inline(__always)
    public static func string(_ key: LocalizationKey, localeIdentifier: String? = nil) -> String {
        let selectedBundle = localeIdentifier.flatMap(localizedBundle(for:)) ?? bundle
        return NSLocalizedString(
            key.rawValue,
            tableName: nil,
            bundle: selectedBundle,
            value: key.rawValue,
            comment: ""
        )
    }

    public static func format(
        _ key: LocalizationKey,
        localeIdentifier: String? = nil,
        _ arguments: CVarArg...
    ) -> String {
        let locale = localeIdentifier.map(Locale.init(identifier:)) ?? .current
        return String(
            format: string(key, localeIdentifier: localeIdentifier),
            locale: locale,
            arguments: arguments
        )
    }

    private static func localizedBundle(for localeIdentifier: String) -> Bundle? {
        let candidates = [
            localeIdentifier,
            Locale(identifier: localeIdentifier).language.languageCode?.identifier
        ].compactMap { $0 }

        for candidate in candidates {
            if let path = bundle.path(forResource: candidate, ofType: "lproj"),
               let localizedBundle = Bundle(path: path) {
                return localizedBundle
            }
        }
        return nil
    }
}
