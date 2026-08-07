import XCTest
@testable import whistleYooApp

@MainActor
final class UpdateControllerTests: XCTestCase {
    func testOnlyZeroVersionIsTreatedAsLocalTestingBuild() {
        XCTAssertTrue(UpdateController.isLocalTestingVersion("0.0.0"))
        XCTAssertFalse(UpdateController.isLocalTestingVersion("0.0.1"))
        XCTAssertFalse(UpdateController.isLocalTestingVersion("1.0.0"))
        XCTAssertFalse(UpdateController.isLocalTestingVersion(nil))
    }
}
