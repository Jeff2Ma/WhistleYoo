import Foundation
import XCTest
@testable import whistleYooCore

final class MCPTokenStoreTests: XCTestCase {
    func testTokenIsStableRotatableAndOwnerOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("mcp-token")
        let store = MCPTokenStore(fileURL: url)

        let first = try store.loadOrCreate()
        XCTAssertEqual(first, try store.loadOrCreate())
        XCTAssertNotEqual(first, try store.rotate())
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
