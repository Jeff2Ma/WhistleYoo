import Foundation
import XCTest
@testable import whistleYooCore

final class LocalizationTests: XCTestCase {
    func testTypedKeysMatchCatalogAndIncludeSupportedLanguages() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let catalogURL = repositoryRoot
            .appendingPathComponent("Sources/whistleYooCore/Resources/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let catalog = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        let typedKeys = Set(LocalizationKey.allCases.map(\.rawValue))

        XCTAssertEqual(Set(strings.keys), typedKeys)

        for key in typedKeys.sorted() {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], key)
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any],
                key
            )
            XCTAssertNotNil(localizations["en"], "Missing English localization for \(key)")
            XCTAssertNotNil(localizations["zh-Hans"], "Missing Simplified Chinese localization for \(key)")
        }
    }
}
